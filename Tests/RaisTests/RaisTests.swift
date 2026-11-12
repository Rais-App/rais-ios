import UIKit
import XCTest
@testable import Rais

final class CheckoutURLTests: XCTestCase {
    private func trusted(_ string: String, extra: [String] = []) -> Bool {
        CheckoutURL.isTrusted(URL(string: string)!, additionalHosts: extra)
    }

    func testRaisHostsAreTrustedOverHTTPS() {
        XCTAssertTrue(trusted("https://pay.rais.app/pay/95855e6f-fcbd-44cb-ac78-5e2c36cf8b0f"))
        XCTAssertTrue(trusted("https://rais.app/x"))
        XCTAssertTrue(trusted("https://sandbox.pay.rais.app/x"))
    }

    func testPlainHTTPAndLookalikesAreRefused() {
        XCTAssertFalse(trusted("http://pay.rais.app/pay/x"))
        XCTAssertFalse(trusted("https://rais.app.evil.example/pay/x"))
        XCTAssertFalse(trusted("https://evilrais.app/pay/x"))
        XCTAssertFalse(trusted("https://example.com/pay/x"))
        XCTAssertFalse(trusted("myapp://pay/x"))
    }

    func testLoopbackIsAllowedForLocalTesting() {
        XCTAssertTrue(trusted("http://localhost:8585/pay/x"))
        XCTAssertTrue(trusted("http://127.0.0.1:8585/pay/x"))
    }

    func testAdditionalHostsAreExactMatches() {
        XCTAssertTrue(trusted("https://pay.staging.example/p", extra: ["pay.staging.example"]))
        XCTAssertFalse(trusted("https://other.staging.example/p", extra: ["pay.staging.example"]))
    }

    func testALanguageGoesThroughTheSitesLanguageSwitch() {
        let checkout = URL(string: "https://pay.rais.app/pay/95855e6f-fcbd-44cb-ac78-5e2c36cf8b0f")!
        XCTAssertEqual(CheckoutURL.entry(checkout, languageCode: nil), checkout)
        XCTAssertEqual(CheckoutURL.entry(checkout, languageCode: "fr").absoluteString,
                       "https://pay.rais.app/lang/fr?next=%2Fpay%2F95855e6f%2Dfcbd%2D44cb%2Dac78%2D5e2c36cf8b0f")
        XCTAssertEqual(CheckoutURL.entry(checkout, languageCode: "xx"), checkout, "only the languages of the page")
    }

    func testTheLanguageSwitchKeepsThePortAndQueryOfTheCheckout() {
        let local = URL(string: "http://localhost:8585/pay/abc?x=1&y=2")!
        let entry = CheckoutURL.entry(local, languageCode: "ar")
        XCTAssertEqual(entry.host, "localhost")
        XCTAssertEqual(entry.port, 8585)
        XCTAssertEqual(URLComponents(url: entry, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "/pay/abc?x=1&y=2")
    }

    func testSameOriginComparesSchemeHostAndPort() {
        let origin = URL(string: "https://pay.rais.app/pay/a")!
        XCTAssertTrue(CheckoutURL.isSameOrigin(URL(string: "https://pay.rais.app:443/payment/confirm?x=1"), as: origin))
        XCTAssertFalse(CheckoutURL.isSameOrigin(URL(string: "https://rais.app/terms"), as: origin))
        XCTAssertFalse(CheckoutURL.isSameOrigin(URL(string: "http://pay.rais.app/pay/a"), as: origin))
        XCTAssertFalse(CheckoutURL.isSameOrigin(nil, as: origin))
    }
}

final class PageMessageTests: XCTestCase {
    private let id = "95855E6F-FCBD-44CB-AC78-5E2C36CF8B0F"

    func testResultIsParsedAndTheIdIsLowercased() {
        let message = PageMessage.parse(["type": "result", "status": "paid", "paymentId": id, "reference": "order-1", "orderNumber": "RS1"])
        XCTAssertEqual(message, .result(status: .paid, paymentID: id.lowercased(), reference: "order-1", orderNumber: "RS1"))
    }

    func testMalformedMessagesAreIgnored() {
        XCTAssertNil(PageMessage.parse("not a dictionary"))
        XCTAssertNil(PageMessage.parse(["type": "result", "status": "paid", "paymentId": "not-a-uuid"]))
        XCTAssertNil(PageMessage.parse(["type": "result", "status": "teleported", "paymentId": id]))
        XCTAssertNil(PageMessage.parse(["type": "launch-missiles"]))
        XCTAssertNil(PageMessage.parse(["status": "paid"]))
    }

    func testOptionalFieldsAreBounded() {
        let long = String(repeating: "x", count: 500)
        let message = PageMessage.parse(["type": "result", "status": "failed", "paymentId": id, "reference": long])
        XCTAssertEqual(message, .result(status: .failed, paymentID: id.lowercased(), reference: nil, orderNumber: nil))
    }

    func testReadyKnowsPayPagesFromResultPages() {
        XCTAssertEqual(PageMessage.parse(["type": "ready", "page": "pay"]), .ready(page: "pay", rtl: false))
        XCTAssertEqual(PageMessage.parse(["type": "ready"]), .ready(page: "result", rtl: false))
        XCTAssertEqual(PageMessage.parse(["type": "ready", "page": "pay", "dir": "rtl"]), .ready(page: "pay", rtl: true))
        XCTAssertEqual(PageMessage.parse(["type": "ready", "dir": "sideways"]), .ready(page: "result", rtl: false))
        XCTAssertEqual(PageMessage.parse(["type": "done"]), .done)
        XCTAssertEqual(PageMessage.parse(["type": "close"]), .close)
    }
}

final class AppearanceTests: XCTestCase {
    func testDefaultsSendNothingToThePage() {
        let payload = RaisCheckout.Appearance().payload(style: .light)
        XCTAssertTrue(payload.isEmpty, "an untouched appearance keeps every Raïs default")
    }

    func testColorsAreSentAsHex() {
        var appearance = RaisCheckout.Appearance()
        appearance.colors.primary = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        appearance.colors.border = UIColor(red: 0, green: 0, blue: 1, alpha: 0.5)
        let colors = appearance.payload(style: .light)["colors"] as? [String: String]
        XCTAssertEqual(colors?["primary"], "#ff0000")
        XCTAssertEqual(colors?["border"], "#0000ff80")
    }

    func testDynamicColorsAreReadForTheSchemeOnScreen() {
        var appearance = RaisCheckout.Appearance()
        appearance.colors.primary = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 1) : UIColor(white: 0, alpha: 1) }
        XCTAssertEqual((appearance.payload(style: .dark)["colors"] as? [String: String])?["primary"], "#ffffff")
        XCTAssertEqual((appearance.payload(style: .light)["colors"] as? [String: String])?["primary"], "#000000")
    }

    func testCornerRadiusIsClamped() {
        var appearance = RaisCheckout.Appearance()
        appearance.cornerRadius = 80
        XCTAssertEqual(appearance.payload(style: .light)["cornerRadius"] as? Double, 24)
        appearance.cornerRadius = -5
        XCTAssertEqual(appearance.payload(style: .light)["cornerRadius"] as? Double, 0)
    }

    func testEffectiveStyleFollowsTheDeviceOnlyWhenAutomatic() {
        var appearance = RaisCheckout.Appearance()
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(appearance.effectiveStyle(for: dark), .dark)
        appearance.colorScheme = .light
        XCTAssertEqual(appearance.effectiveStyle(for: dark), .light)
    }

    func testBackgroundMatchesThePagePalette() {
        let appearance = RaisCheckout.Appearance()
        var white: CGFloat = 0
        appearance.backgroundColor(style: .dark).getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.1)
        appearance.backgroundColor(style: .light).getWhite(&white, alpha: nil)
        XCTAssertEqual(white, 1, accuracy: 0.001)
    }
}

final class CheckoutTests: XCTestCase {
    func testAnInvalidAddressFailsWithoutPresenting() {
        let checkout = RaisCheckout(checkoutURL: URL(string: "https://example.com/pay/x")!)
        XCTAssertFalse(checkout.isValid)
        let done = expectation(description: "completion")
        checkout.present(from: UIViewController()) { result in
            if case .failed(let failure) = result { XCTAssertEqual(failure.code, .invalidURL) } else { XCTFail("expected a failure") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testLanguageCodes() {
        XCTAssertNil(RaisCheckout.Language.automatic.code)
        XCTAssertEqual(RaisCheckout.Language.arabic.code, "ar")
    }
}
