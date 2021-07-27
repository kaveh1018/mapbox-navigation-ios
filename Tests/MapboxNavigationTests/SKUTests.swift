import XCTest
import TestHelper
@testable import MapboxCoreNavigation
import MapboxDirections
import MapboxSpeech
import MapboxNavigation
import MapboxCommon_Private

class SKUTests: TestCase {
    func testDirectionsSKU() {
        billingServiceMock.onGetSKUTokenIfValid = { _ in
            TokenGenerator.getSKUToken(for: .nav2SesTrip)
        }
        XCTAssertEqual(Directions.skuToken, "")
        BillingHandler.shared.beginBillingSession(for: .freeDrive, uuid: .init())
        let directionsSkuToken = Directions.skuToken
        
        XCTAssertNotNil(directionsSkuToken)
        
        XCTAssertEqual(directionsSkuToken?.skuId, SkuID.nav2SesTrip.rawValue)
    }
    
    func testSpeechSynthesizerSKU() {
        billingServiceMock.onGetSKUTokenIfValid = { _ in
            TokenGenerator.getSKUToken(for: .nav2SesTrip)
        }
        XCTAssertEqual(Directions.skuToken, "")
        BillingHandler.shared.beginBillingSession(for: .freeDrive, uuid: .init())

        let speechSkuToken = SpeechSynthesizer.skuToken
        
        XCTAssertNotNil(speechSkuToken)
        
        XCTAssertEqual(speechSkuToken?.skuId, SkuID.nav2SesTrip.rawValue)
    }

    func testSKUTokensMatch() {
        BillingHandler.shared.beginBillingSession(for: .freeDrive, uuid: .init())
        let skuToken = TokenGenerator.getSKUToken(for: .nav2SesTrip)
        billingServiceMock.onGetSKUTokenIfValid = { _ in skuToken }

        let viewController = TokenTestViewController()
        let tokenExpectation = XCTestExpectation(description: "All tokens should be fetched")
        viewController.tokenExpectation = tokenExpectation

        viewController.simulatateViewControllerPresented()

        wait(for: [tokenExpectation], timeout: 5)

        XCTAssertNotEqual(viewController.mapViewToken?.skuId, SkuID.navigationUser.rawValue)
        XCTAssertNotEqual(viewController.mapViewToken, viewController.directionsToken)
        XCTAssertNotEqual(viewController.mapViewToken, viewController.speechSynthesizerToken)
        XCTAssertEqual(viewController.speechSynthesizerToken, skuToken)
        XCTAssertEqual(viewController.directionsToken, skuToken)
    }
}
