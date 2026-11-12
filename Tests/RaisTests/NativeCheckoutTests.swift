import XCTest
@testable import Rais

/// The parts of the native checkout that are rules, not drawing: where an address points, the card fields, the proof of work, the answer
/// of `GET /pay/{id}/sheet`.
final class NativeCheckoutTests: XCTestCase {
    private let id = "95855e6f-fcbd-44cb-ac78-5e2c36cf8b0f"

    func testAPaymentAddressNamesItsSiteAndItsPayment() throws {
        let plain = try XCTUnwrap(CheckoutAPI.Location(URL(string: "https://pay.rais.app/pay/\(id.uppercased())")!))
        XCTAssertEqual(plain.origin.absoluteString, "https://pay.rais.app")
        XCTAssertEqual(plain.paymentID, id)
        XCTAssertTrue(plain.isPlain)
        XCTAssertEqual(plain.pageURL.absoluteString, "https://pay.rais.app/pay/\(id)")

        let session = try XCTUnwrap(CheckoutAPI.Location(URL(string: "http://localhost:8585/pay/\(id)/raisid?a=token&card=1")!))
        XCTAssertEqual(session.origin.absoluteString, "http://localhost:8585")
        XCTAssertFalse(session.isPlain, "the address that identifies the payer is visited once before the checkout is read")
    }

    func testAnAddressThatIsNotAPaymentGoesToTheWebCheckout() {
        for other in ["https://pay.rais.app/", "https://pay.rais.app/pay/not-a-payment", "https://pay.rais.app/lang/fr?next=%2Fpay%2F\(id)"] {
            XCTAssertNil(CheckoutAPI.Location(URL(string: other)!), other)
        }
    }

    func testCardNumbersAreWrittenInGroupsAndReadInAnyDigits() {
        XCTAssertEqual(CardRules.formatPAN("6280581110007215"), "6280 5811 1000 7215")
        XCTAssertEqual(CardRules.formatPAN("٦٢٨٠ ٥٨١١"), "6280 5811")
        XCTAssertEqual(CardRules.formatPAN(String(repeating: "1", count: 30)).filter(\.isNumber).count, 19)
        XCTAssertEqual(CardRules.brand(of: "6280581110007215"), .edahabia)
        XCTAssertEqual(CardRules.brand(of: "6219000000000000"), .cib)
        XCTAssertNil(CardRules.brand(of: "4111"))
        XCTAssertEqual(CardRules.formatMasked("628058******7215"), "6280 58•• •••• 7215")
    }

    func testExpiryIsWrittenAsMonthAndYear() {
        XCTAssertEqual(CardRules.formatExpiry("1"), "1")
        XCTAssertEqual(CardRules.formatExpiry("5"), "05 / ")
        XCTAssertEqual(CardRules.formatExpiry("12"), "12 / ")
        XCTAssertEqual(CardRules.formatExpiry("1227"), "12 / 27")
    }

    func testTheChecksAreThePagesOwn() {
        XCTAssertEqual(CardRules.checkPAN("", sandbox: false), "js.pan_required")
        XCTAssertEqual(CardRules.checkPAN("6280 5811 1000 7216", sandbox: false), "js.pan_invalid", "a wrong check digit")
        XCTAssertNil(CardRules.checkPAN("6280 5811 1000 7216", sandbox: true), "a test payment lets the gateway refuse it")
        XCTAssertNil(CardRules.checkPAN("6280 5811 1000 7215", sandbox: false))
        let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 13).date!
        XCTAssertEqual(CardRules.checkExpiry("10 / 26", sandbox: false, now: now), "js.expiry_past")
        XCTAssertNil(CardRules.checkExpiry("11 / 26", sandbox: false, now: now))
        XCTAssertEqual(CardRules.checkExpiry("13 / 27", sandbox: false, now: now), "js.expiry_invalid")
        XCTAssertNil(CardRules.checkExpiry("10 / 26", sandbox: true, now: now))
        XCTAssertEqual(CardRules.checkCVC("12"), "js.cvc_invalid")
        XCTAssertNil(CardRules.checkCVC("123"))
        XCTAssertEqual(CardRules.checkName(" "), "js.name_required")
        XCTAssertEqual(CardRules.checkName("أمينة"), "js.name_invalid")
        XCTAssertNil(CardRules.checkName("Amina  Bénali"))
        XCTAssertEqual(CardRules.cleanName("Amina  Bénali"), "Amina Benali")
        XCTAssertNil(CardRules.checkEmail(""))
        XCTAssertNil(CardRules.checkEmail("amina@example.dz"))
        XCTAssertEqual(CardRules.checkEmail("amina@example"), "js.email_invalid")
    }

    /// The values the server's own implementation gives (app/services/captcha.py): an answer found here is accepted there.
    func testTheProofOfWorkIsTheServers() {
        XCTAssertEqual(ProofOfWork.fnv1a("abc"), 440_920_331)
        XCTAssertEqual(ProofOfWork.prng("token1", length: 32), "8539570754e5fd8b81c9ec01357bd685")
        XCTAssertEqual(ProofOfWork.prng("token1d", length: 4), "4bb7")
        XCTAssertEqual(ProofOfWork.solveOne(salt: "54c084d8cf2f7855249cc0a72d87a283", target: "f24e"), 137_677)
        XCTAssertEqual(ProofOfWork.solve(token: "tok.sig", count: 3, size: 32, difficulty: 4)?[2], 137_677)
        XCTAssertNil(ProofOfWork.solve(token: "tok.sig", count: 0, size: 32, difficulty: 4))
    }

    func testTheSheetIsReadAsTheServerWritesIt() throws {
        let json = """
        {"v":1,"state":"pay","language":"ar","rtl":true,"sandbox":true,
         "payment":{"id":"\(id)","amount":450000,"amount_text":"4,500.00 DA","amount_number":"4,500.00","currency":"DA","description":null,
                    "lines":[{"name":"Tea","description":null,"quantity":"2 × 2,000.00 DA","total_text":"4,000.00 DA"}],"adjustment_text":null,
                    "details":[{"label":"Reference","value":"REF-7","mono":true}]},
         "merchant":{"name":"Dar El Baraka","logo_url":"https://pay.rais.app/logos/x.png","website":"baraka.example"},
         "text":{"pay.card_number":"Card number","js.session":"Session expires in {time}","js.code.expired":"This payment link has expired."},
         "pay":{"mode":"custom","captcha":true,"session_seconds":570,"otp_length":6,"payer":{"first_name":"Amina"},
                "balance":{"text":"3,000.00 DA","enough":false,"topup_url":"https://rais.app/dashboard/top-up","short_text":"Too low"},
                "cards":[{"id":"c1","kind":"wallet","last4":"7215","expiry":"01/27","brand":"edahabia","needs_cvc":false}],
                "chosen":"c1","app_url":null,"save":{"label":"Save this card","checked":true},"receipt_email":true,
                "terms_url":"https://rais.app/terms","otp_pending":false,"something_new":42}}
        """
        let sheet = try JSONDecoder().decode(Sheet.self, from: Data(json.utf8))
        XCTAssertEqual(sheet.state, .pay)
        XCTAssertTrue(sheet.rtl)
        XCTAssertEqual(sheet.payment?.lines.first?.totalText, "4,000.00 DA")
        XCTAssertEqual(sheet.payment?.details.first?.mono, true)
        XCTAssertEqual(sheet.merchant?.logoURL?.host, "pay.rais.app")
        XCTAssertEqual(sheet.pay?.cards.first?.kind, .wallet)
        XCTAssertEqual(sheet.pay?.balance?.enough, false)
        XCTAssertEqual(sheet.pay?.captcha, true)
        let words = Words(table: sheet.text)
        XCTAssertEqual(words["pay.card_number"], "Card number", "the keys of the words are kept as the server names them")
        XCTAssertEqual(words("js.session", ["time": "9:41"]), "Session expires in 9:41")
        XCTAssertEqual(words.describing(.init(status: 409, code: "expired", message: "x", field: nil, retry: false)), "This payment link has expired.")
        XCTAssertEqual(words.describing(.init(status: 200, code: nil, message: "Carte bloquée", field: nil, retry: false)), "Carte bloquée")
    }

    func testAResultCarriesWhatTheAppIsTold() throws {
        let json = """
        {"v":1,"state":"result","language":"en","rtl":false,"sandbox":false,"text":{},
         "payment":{"id":"\(id)","amount":1000,"amount_text":"10.00 DA"},"merchant":{"name":"Shop","logo_url":null,"website":null},
         "result":{"tone":"ok","icon":"check","title":"Payment Successful","lead":"Approved","note":null,"rows":[{"label":"Amount","value":"10.00 DA"}],
                   "support":null,"receipt":{"url":"https://pay.rais.app/pay/\(id)/receipt.pdf","mail":{"sent":false,"to":null,"known":"a***@example.dz"}},
                   "retry":false,"contact_email":null,"outcome":{"status":"paid","payment_id":"\(id)","reference":"REF-7","order_number":"RS1"}}}
        """
        let result = try XCTUnwrap(JSONDecoder().decode(Sheet.self, from: Data(json.utf8)).result)
        XCTAssertEqual(result.tone, .ok)
        XCTAssertEqual(result.outcome?.status, "paid")
        XCTAssertEqual(result.outcome?.orderNumber, "RS1")
        XCTAssertEqual(result.receipt?.mail?.known, "a***@example.dz")
        XCTAssertNil(result.confirming)
    }
}
