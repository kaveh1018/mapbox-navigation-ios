import Foundation
import MapboxDirections
@_implementationOnly import MapboxCommon_Private

/// BillingService from MapboxCommon
private typealias BillingServiceNative = MapboxCommon_Private.BillingService
/// BillingServiceError from MapboxCommon
private typealias BillingServiceErrorNative = MapboxCommon_Private.BillingServiceError

/// Swift variant of `BillingServiceErrorNative`
enum BillingServiceError: Error {
    /// Unknown error from Billing Service
    case unknown

    /// Provided SKU ID is invalid.
    case invalidSkuId
    /// The request failed because the access token is invalid.
    case tokenValidationFailed
    /// The resume failed because the session doesn't exist or invalid.
    case resumeFailed

    fileprivate init(_ nativeError: BillingServiceErrorNative) {
        switch nativeError.code {
        case .invalidSkuId:
            self = .invalidSkuId
        case .resumeFailed:
            self = .resumeFailed
        case .tokenValidationFailed:
            self = .tokenValidationFailed
        @unknown default:
            self = .unknown
        }
    }
}

/// Protocol for `BillingServiceNative` implementation. Inversing the dependency on `BillingServiceNative` allows us
/// to unit test our implementation.
protocol BillingService {
    func getSKUTokenIfValid(for sessionType: BillingHandler.SessionType) -> String
    func beginBillingSession(for sessionType: BillingHandler.SessionType,
                             onError: @escaping (BillingServiceError) -> Void)
    func pauseBillingSession(for sessionType: BillingHandler.SessionType)
    func resumeBillingSession(for sessionType: BillingHandler.SessionType,
                              onError: @escaping (BillingServiceError) -> Void)
    func stopBillingSession(for sessionType: BillingHandler.SessionType)
    func triggerBillingEvent(onError: @escaping (BillingServiceError) -> Void)
    func getSessionStatus(for sessionType: BillingHandler.SessionType) -> BillingHandler.SessionState
}

/// Implementation of `BillingService` protocol which uses `BillingServiceNative`.
private final class ProductionBillingService: BillingService {
    /// Mapbox access token which will be included in the billing requests.
    private let accessToken: String
    /// The User Agent string which will be included in the billing requests.
    private let userAgent: String
    /// `SKUIdentifier` which is used for navigation MAU billing events.
    private let mauSku: SKUIdentifier = .nav2SesMAU

    /// The lock to protect internal state.
    private let lock: NSLock = .init()
    /**
     The state of the `BillingService` session per `SKUIdentifier`.

     Will be replaced with `BillingServiceNative` implementation once available.
     */
    private var _sessionState: [SKUIdentifier: BillingHandler.SessionState] = [:]

    /**
     Creates a new instance of `ProductionBillingService` which uses provided `accessToken` and `userAgent` for
     billing requests.

     - Parameters:
     - accessToken: Mapbox access token which will be included in the billing requests.
     - userAgent: The User Agent string which will be included in the billing requests.
     */
    init(accessToken: String, userAgent: String) {
        self.accessToken = accessToken
        self.userAgent = userAgent
    }

    func getSKUTokenIfValid(for sessionType: BillingHandler.SessionType) -> String {
        return TokenGenerator.getSKUTokenIfValid(for: tripSku(for: sessionType))
    }

    func beginBillingSession(for sessionType: BillingHandler.SessionType,
                             onError: @escaping (BillingServiceError) -> Void) {
        let skuToken = tripSku(for: sessionType)
        lock {
            _sessionState[skuToken] = .running
        }
        print(">>>> Beging Billing Session: \(sessionType)")
        BillingServiceNative.beginBillingSession(forAccessToken: accessToken,
                                                 userAgent: userAgent,
                                                 skuIdentifier: skuToken,
                                                 callback: { nativeBillingServiceError in
                                                    self.lock {
                                                        self._sessionState[skuToken] = .stopped
                                                    }
                                                    onError(BillingServiceError(nativeBillingServiceError))
                                                 }, validity: sessionType.maxSessionInterval)
    }

    func pauseBillingSession(for sessionType: BillingHandler.SessionType) {
        print(">>>> Pause Billing Session \(sessionType)")
        let skuToken = tripSku(for: sessionType)
        lock {
            _sessionState[skuToken] = .paused
        }
        BillingServiceNative.pauseBillingSession(for: skuToken)
    }

    func resumeBillingSession(for sessionType: BillingHandler.SessionType,
                              onError: @escaping (BillingServiceError) -> Void) {
        let skuToken = tripSku(for: sessionType)
        BillingServiceNative.resumeBillingSession(for: skuToken) { nativeBillingServiceError in
            self.lock {
                self._sessionState[skuToken] = .stopped
            }
            onError(BillingServiceError(nativeBillingServiceError))
        }
        print(">>>> Resume Billing Session \(sessionType)")
    }

    func stopBillingSession(for sessionType: BillingHandler.SessionType) {
        let skuToken = tripSku(for: sessionType)
        lock {
            _sessionState[skuToken] = .stopped
        }
        print(">>>> Stop Billing Session \(sessionType)")
        BillingServiceNative.stopBillingSession(for: skuToken)
    }

    func triggerBillingEvent(onError: @escaping (BillingServiceError) -> Void) {
        print(">>>> MAU Event")
        BillingServiceNative.triggerBillingEvent(forAccessToken: accessToken,
                                                 userAgent: userAgent,
                                                 skuIdentifier: mauSku) { nativeBillingServiceError in
            onError(BillingServiceError(nativeBillingServiceError))
        }
    }

    func getSessionStatus(for sessionType: BillingHandler.SessionType) -> BillingHandler.SessionState {
        return lock {
            _sessionState[tripSku(for: sessionType)] ?? .stopped
        }
    }

    private func tripSku(for sessionType: BillingHandler.SessionType) -> SKUIdentifier {
        switch sessionType {
        case .activeGuidance:
            return .nav2SesTrip
        case .freeDrive:
            return .nav2SesTrip
        }
    }
}

/**
 Receives events about navigation changes and triggers appropriate events in `BillingService`.

 Session can be paused (`BillingHandler.pauseBillingSession(with:)`),
 stopped (`BillingHandler.stopBillingSession(with:)`) or
 resumed (`BillingHandler.resumeBillingSession(with:)`).

 State of the billing sessions can be obtained using `BillingHandler.sessionState(uuid:)`.
 */
final class BillingHandler {
    /// Parameters on an active session.
    private struct Session {
        let type: SessionType
        /// Indicates whether the session is active but paused.
        var isPaused: Bool
    }

    /// The state of the billing session.
    enum SessionState: Equatable {
        /// Indicates that there is no active billing session.
        case stopped
        /// There is an active paused billing session.
        case paused
        /// There is an active running billing session.
        case running
    }

    /// Supported session types.
    enum SessionType: Equatable {
        case freeDrive
        case activeGuidance

        var maxSessionInterval: TimeInterval {
            switch self {
            case .activeGuidance:
                return 43200 /*12h*/
            case .freeDrive:
                return 3600 /*2h*/
            }
        }
    }

    /// Shared billing handler instance. There is no other instances of `BillingHandler`.
    private(set) static var shared: BillingHandler = {
        let accessToken = Directions.shared.credentials.accessToken
        precondition(accessToken != nil, "A Mapbox access token is required. Go to <https://account.mapbox.com/access-tokens/>. In Info.plist, set the MBXAccessToken key to your access token.")
        let service = ProductionBillingService(accessToken: accessToken ?? "",
                                               userAgent: URLSession.userAgent)
        return .init(service: service)
    }()

    /// The billing service which is used to send billing events.
    private let billingService: BillingService

    /**
     A lock which serializes access to variables with underscore: `_sessions` etc.
     As a convention, all class-level identifiers that starts with `_` should be executed with locked `lock`.
     */
    private let lock: NSLock = .init()

    /// All currently active sessions. Running or paused. When session is stopped, it is removed from this variable.
    private var _sessions: [UUID: Session] = [:]

    /**
     The state of the billing session.

     - important: This variable is safe to use from any thread.
     - parameter uuid: Session UUID which is provided in `BillingHandler.beginBillingSession(for:uuid:)`.
     */
    func sessionState(uuid: UUID) -> SessionState {
        lock.lock(); defer {
            lock.unlock()
        }

        guard let session = _sessions[uuid] else {
            return .stopped
        }

        if session.isPaused {
            return .paused
        }
        else {
            return .running
        }
    }

    /// The token to use for service requests like `Directions` etc. 
    var serviceSkuToken: String {
        let sessionType = lock { _sessionTypeForRequests() }

        if let sessionType = sessionType {
            return billingService.getSKUTokenIfValid(for: sessionType)
        }
        else {
            return ""
        }
    }

    private init(service: BillingService) {
        self.billingService = service
    }

    /**
     Starts a new billing session of the given `sessionType` identified by `uuid`.

     The `uuid` that is used to create a billing session must be provided in the following methods to perform
     relevant changes to the started billing session:
     - `BillingHandler.stopBillingSession(with:)`
     - `BillingHandler.pauseBillingSession(with:)`
     - `BillingHandler.resumeBillingSession(with:)`

     - Parameters:
     - sessionType: The type of the billing session.
     - uuid: The unique identifier of the billing session.
     */
    func beginBillingSession(for sessionType: SessionType, uuid: UUID) {
        lock.lock()

        if var existingSession = _sessions[uuid] {
            existingSession.isPaused = false
            _sessions[uuid] = existingSession
        }
        else {
            let session = Session(type: sessionType, isPaused: false)
            _sessions[uuid] = session
        }
        lock.unlock()

        let triggerBillingServiceEvents = billingService.getSessionStatus(for: sessionType) != .running
        if triggerBillingServiceEvents {
            billingService.triggerBillingEvent(onError: { error in
                print(error)
            })
            billingService.beginBillingSession(for: sessionType, onError: { [weak self] error in
                self?.failedToBeginBillingSession(with: uuid, with: error)
            })
        }
    }

    /// Stops the billing session identified by the `uuid`.
    func stopBillingSession(with uuid: UUID) {
        lock.lock()
        guard let session = _sessions[uuid] else {
            lock.unlock(); return
        }
        _sessions[uuid] = nil

        let triggerBillingServiceEvents = !_hasSession(with: session.type)
            && billingService.getSessionStatus(for: session.type) != .stopped
        lock.unlock()

        if triggerBillingServiceEvents {
            billingService.stopBillingSession(for: session.type)
        }
    }
 
    /// Pauses the billing session identified by the `uuid`.
    func pauseBillingSession(with uuid: UUID) {
        lock.lock()
        guard var session = _sessions[uuid] else {
            assertionFailure("Trying to pause non-existing session.")
            lock.unlock(); return
        }
        session.isPaused = true
        _sessions[uuid] = session


        let triggerBillingServiceEvent = !_hasSession(with: session.type, isPaused: false)
            && billingService.getSessionStatus(for: session.type) == .running
        lock.unlock()

        if triggerBillingServiceEvent {
            billingService.pauseBillingSession(for: session.type)
        }
    }
    
    /// Resumes the billing session identified by the `uuid`.
    func resumeBillingSession(with uuid: UUID) {
        lock.lock()
        guard var session = _sessions[uuid] else {
            assertionFailure("Trying to pause non-existing session.")
            lock.unlock(); return
        }
        session.isPaused = false
        _sessions[uuid] = session
        let triggerBillingServiceEvent = billingService.getSessionStatus(for: session.type) == .paused
        lock.unlock()

        if triggerBillingServiceEvent {
            billingService.resumeBillingSession(for: session.type) { _ in
                self.failedToResumeBillingSession(with: uuid)
            }
        }
    }

    private func failedToBeginBillingSession(with uuid: UUID, with error: Error) {
        lock {
            _sessions[uuid] = nil
        }
    }

    private func failedToResumeBillingSession(with uuid: UUID) {
        lock.lock()
        guard let session = _sessions[uuid] else {
            lock.unlock(); return
        }
        _sessions[uuid] = nil
        lock.unlock()
        beginBillingSession(for: session.type, uuid: uuid)
    }

    private func _sessionTypeForRequests() -> SessionType? {
        for session in _sessions.values {
            if session.type == .activeGuidance {
                return .activeGuidance
            }
        }
        if _sessions.isEmpty {
            return nil
        }
        else {
            return .freeDrive
        }
    }

    private func _hasSession(with type: SessionType) -> Bool {
        return _sessions.contains(where: { $0.value.type == type })
    }

    private func _hasSession(with type: SessionType, isPaused: Bool) -> Bool {
        return _sessions.values.contains { session in
            session.type == type && session.isPaused == isPaused
        }
    }
}

// MARK: - Tests support

extension BillingHandler {
    static func __createMockedHandler(with service: BillingService) -> BillingHandler {
        BillingHandler(service: service)
    }

    static func __replaceShareInstance(with handler: BillingHandler) {
        BillingHandler.shared = handler
    }
}
