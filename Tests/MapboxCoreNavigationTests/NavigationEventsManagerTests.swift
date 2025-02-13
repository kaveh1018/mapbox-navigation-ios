import XCTest
import MapboxMobileEvents
@testable import TestHelper
@testable import MapboxCoreNavigation

class NavigationEventsManagerTests: TestCase {
    func testMobileEventsManagerIsInitializedImmediately() {
        let mobileEventsManagerSpy = MMEEventsManagerSpy()
        let _ = NavigationEventsManager(accessToken: "example token", mobileEventsManager: mobileEventsManagerSpy)

        let config = UserDefaults.mme_configuration()
        let token = config.mme_accessToken
        XCTAssertEqual(token, "example token")
    }
    
    func skipped_testDepartRerouteArrive() {
        
        let firstRouteOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 38.853108, longitude: -77.043331),
            CLLocationCoordinate2D(latitude: 38.910736, longitude: -76.966906),
        ])
        let firstRoute = Fixture.route(from: "DCA-Arboretum", options: firstRouteOptions)
        
        let secondRouteOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 42.361634, longitude: -71.12852),
            CLLocationCoordinate2D(latitude: 42.352396, longitude: -71.068719),
        ])
        let secondRoute = Fixture.route(from: "PipeFittersUnion-FourSeasonsBoston", options: secondRouteOptions)
        
        let firstTrace = Array<CLLocation>(Fixture.generateTrace(for: firstRoute).prefix(upTo: firstRoute.shape!.coordinates.count / 2)).shiftedToPresent().qualified()
        let secondTrace = Fixture.generateTrace(for: secondRoute).shifted(to: firstTrace.last!.timestamp + 1).qualified()
        
        let locationManager = NavigationLocationManager()
        let service = MapboxNavigationService(route: firstRoute, routeIndex: 0,
                                              routeOptions: firstRouteOptions,
                                              directions: directions,
                                              locationSource: locationManager,
                                              eventsManagerType: NavigationEventsManagerSpy.self,
                                              simulating: .always)
        service.start()
        
        for location in firstTrace {
            service.router.locationManager!(locationManager, didUpdateLocations: [location])
        }

        service.router.updateRoute(with: (secondRoute, 0), routeOptions: nil)
        
        for location in secondTrace {
            service.router.locationManager!(locationManager, didUpdateLocations: [location])
        }
        
        let eventsManager = service.eventsManager as! NavigationEventsManagerSpy
        let events = eventsManager.debuggableEvents
        
        XCTAssertEqual(events.count, 3, "There should be one depart, one reroute, and one arrive event.")
        
        guard let departEvent = events.filter({ $0.event == MMEEventTypeNavigationDepart }).first else { XCTFail(); return }
        guard let rerouteEvent = events.filter({ $0.event == MMEEventTypeNavigationReroute }).first else { XCTFail(); return }
        guard let arriveEvent = events
                .filter({ $0.event == MMEEventTypeNavigationArrive })
                .first as? ActiveNavigationEventDetails else { XCTFail(); return }
        
        let durationBetweenDepartAndArrive = arriveEvent.arrivalTimestamp!.timeIntervalSince(departEvent.startTimestamp!)
        let durationBetweenDepartAndReroute = rerouteEvent.created.timeIntervalSince(departEvent.startTimestamp!)
        let durationBetweenRerouteAndArrive = arriveEvent.arrivalTimestamp!.timeIntervalSince(rerouteEvent.created)
        
        XCTAssertEqual(durationBetweenDepartAndArrive, 1041, accuracy: 1)
        XCTAssertEqual(durationBetweenDepartAndReroute, 225, accuracy: 1)
        XCTAssertEqual(durationBetweenRerouteAndArrive, 816, accuracy: 1)
        XCTAssertEqual(arriveEvent.rerouteCount, 1)
    }
    
    // Test allows to verify whether no Main Thread Checker errors occur during
    // NavigationEventDetails object creation.
    func testNavigationEventDetailsGlobalQueue() {
        let routeOptions = NavigationRouteOptions(coordinates: [
            CLLocationCoordinate2D(latitude: 38.853108, longitude: -77.043331),
            CLLocationCoordinate2D(latitude: 38.910736, longitude: -76.966906),
        ])
        let eventTimeout = 0.3
        let route = Fixture.route(from: "DCA-Arboretum", options: routeOptions)
        let dataSource = MapboxNavigationService(route: route, routeIndex: 0, routeOptions: routeOptions, directions: directions, simulating: .onPoorGPS)
        let sessionState = SessionState(currentRoute: route, originalRoute: route)
        
        // Attempt to create NavigationEventDetails object from global queue, no errors from Main Thread Checker
        // are expected.
        let expectation = XCTestExpectation()
        DispatchQueue.global().async {
            let _ = ActiveNavigationEventDetails(dataSource: dataSource, session: sessionState, defaultInterface: false)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: eventTimeout)
        
        // Sanity check to verify that no issues occur when creating NavigationEventDetails from main queue.
        let _ = ActiveNavigationEventDetails(dataSource: dataSource, session: sessionState, defaultInterface: false)
    }
}
