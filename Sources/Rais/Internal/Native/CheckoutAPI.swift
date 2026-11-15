import Foundation
import UIKit

/// The calls of the native checkout: the very ones the hosted page's script makes, to the same addresses, with the same cookies.
///
/// The checkout keeps its state on the server and hands the payer's side of it out as HttpOnly cookies scoped to the payment (who is paying,
/// the bank's step in progress, the robot check that was passed). A private, in-memory `URLSession` holds them here exactly as a browser
/// would, and forgets everything when the checkout closes: nothing of a payment stays on the device.
@MainActor
final class CheckoutAPI {
    /// A call the server answered with a refusal. `code` names it (the screen words it from `Sheet.text`); without a code, `message` is a
    /// sentence the bank's gateway wrote.
    struct Refusal: Error {
        let status: Int
        let code: String?
        let message: String?
        /// The form field the refusal is about (`email`), when it is about one.
        let field: String?
        /// The bank refused this code but its step goes on: another code can be tried.
        let retry: Bool
    }

    enum Failure: Error {
        /// No answer: no network, a timeout, a server that cannot be reached.
        case connection
        /// The server has no native checkout for this address (an older server, or an address that is not a payment's): show the web checkout.
        case unsupported
    }

    /// What a payment call led to.
    enum Step {
        /// The attempt is over, paid or not: `order` names it at the bank (`nil` for a payment from a Raïs balance).
        case complete(order: String?)
        /// The bank asks for the code it sent to the cardholder.
        case code(maskedCard: String?)
    }

    enum Method {
        case newCard(TypedCard, save: Bool)
        case card(Sheet.Pay.Card, cvc: String?)
        case balance
    }

    /// Where a checkout address points: the site, the payment, and whether the address is more than the payment's own page (the app's
    /// checkout session, which first identifies the payer and then redirects there).
    struct Location: Equatable {
        var origin: URL
        let paymentID: String
        let isPlain: Bool

        init?(_ url: URL) {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme, let host = parts.host else { return nil }
            let path = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard path.count >= 2, path[0] == "pay", UUID(uuidString: path[1]) != nil, path[1].count == 36 else { return nil }
            var base = URLComponents()
            base.scheme = scheme
            base.host = host
            base.port = parts.port
            guard let origin = base.url else { return nil }
            self.origin = origin
            paymentID = path[1].lowercased()
            isPlain = path.count == 2
        }

        /// The payment's own page, without anything the address carried.
        var pageURL: URL { origin.appendingPathComponent("pay").appendingPathComponent(paymentID) }
    }

    private(set) var location: Location
    private let checkoutURL: URL
    private let session: URLSession
    private let redirects = RedirectPolicy()
    /// Set once `invalidate()` ran. A call on an invalidated `URLSession` does not fail, it raises an Objective-C exception that kills the app
    /// (the payer returning from the Raïs app after the checkout had ended), so every call checks this first.
    private let ended = NSLock()
    private var isInvalidated = false
    /// A card of the payer to start from, named by the app's checkout session.
    private var preselectedCard: String?
    private var entered = false

    /// The robot check is on for this payment (`Sheet.Pay.captcha`): payment calls need a pass.
    var needsPass = false
    private var passUntil: Date?
    private var passTask: Task<Bool, Never>?

    init(checkoutURL: URL, location: Location, languageCode: String?) {
        self.checkoutURL = checkoutURL
        self.location = location
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 75   // a card call waits for the bank
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "RaisSDK/\(CheckoutURL.version) (iOS; native)", "Accept": "application/json"]
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        // A language the app asked for is the payer's own choice, kept the way the site keeps it (the `rais-locale` cookie): it then decides
        // the words of the screen, of the bank's refusals and of the receipt alike. Without one the server chooses, from the payment and the device.
        if let code = languageCode, let host = location.origin.host,
           let cookie = HTTPCookie(properties: [.name: "rais-locale", .value: code, .domain: host, .path: "/"]) {
            configuration.httpCookieStorage?.setCookie(cookie)
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
    }

    func invalidate() {
        ended.lock()
        isInvalidated = true
        ended.unlock()
        passTask?.cancel()
        session.invalidateAndCancel()
    }

    /// Where "Sign in with Raïs" starts for this payment: the checkout sends the payer to the Raïs website's sign-in and, once they are signed in,
    /// hands the answer to `callbackScheme` (a scheme made up for this one sign-in).
    func signInURL(callbackScheme: String) -> URL {
        var parts = URLComponents(url: location.pageURL.appendingPathComponent("raisid").appendingPathComponent("start"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "native", value: callbackScheme)]
        return parts.url!
    }

    /// Keeps the payer session the sign-in handed over as the page's own cookie (this payment only, as the page sets it): from now on the checkout
    /// knows who is paying and offers their balance and their cards.
    func adoptPayerSession(_ value: String) {
        guard let host = location.origin.host else { return }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "rais_payer", .value: value, .domain: host, .path: "/pay/\(location.paymentID)", .expires: Date().addingTimeInterval(900),
        ]
        if location.origin.scheme == "https" { properties[.secure] = "TRUE" }
        if let cookie = HTTPCookie(properties: properties) { session.configuration.httpCookieStorage?.setCookie(cookie) }
    }

    /// The cookies of this checkout, for the web checkout that takes over when the payment cannot be paid natively.
    var cookies: [HTTPCookie] { session.configuration.httpCookieStorage?.cookies ?? [] }

    // MARK: Reading the checkout

    /// The checkout, read for the first time. An address that is more than the payment's page is visited once (it is single use): it sets the
    /// cookie that says who is paying and redirects to the page, which is not loaded.
    func open() async throws -> Sheet {
        if !location.isPlain, !entered {
            var request = URLRequest(url: checkoutURL)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let (_, response) = try await send(request)
            entered = true
            if let target = response.value(forHTTPHeaderField: "Location"), let parts = URLComponents(string: target) {
                preselectedCard = parts.queryItems?.first { $0.name == "card" }?.value
            }
        }
        return try await sheet()
    }

    /// `order`: the attempt that just ended at the bank, to be confirmed. `fresh`: a payment that was just made from a balance.
    func sheet(order: String? = nil, fresh: Bool = false) async throws -> Sheet {
        var query: [URLQueryItem] = []
        if let preselectedCard { query.append(URLQueryItem(name: "card", value: preselectedCard)) }
        if let order { query.append(URLQueryItem(name: "order", value: order)) }
        if fresh { query.append(URLQueryItem(name: "fresh", value: "1")) }
        return try await sheet(at: url("sheet", query: query))
    }

    func sheet(at address: URL) async throws -> Sheet {
        guard CheckoutURL.isSameOrigin(address, as: location.origin) else { throw Failure.unsupported }
        let (data, response) = try await send(URLRequest(url: address))
        // the site moved this payer to its checkout host (a permanent redirect that was followed): the calls go there from now on
        if let final = response.url, !CheckoutURL.isSameOrigin(final, as: location.origin), let scheme = final.scheme, let host = final.host {
            var base = URLComponents()
            base.scheme = scheme
            base.host = host
            base.port = final.port
            if let origin = base.url { location.origin = origin }
        }
        guard response.statusCode == 200 || response.statusCode == 404, let sheet = try? JSONDecoder().decode(Sheet.self, from: data) else {
            if response.statusCode >= 500 || response.statusCode == 429 { throw Failure.connection }
            throw Failure.unsupported
        }
        needsPass = sheet.pay?.captcha ?? false
        return sheet
    }

    // MARK: Paying

    /// A payment session with the bank for a card that is about to be typed. It lasts about ten minutes.
    func register() async throws {
        let answer = try await call("register", needsPass: true)
        guard answer.json["status"] as? String == "ok" else { throw refusal(answer) }
    }

    func pay(_ method: Method, email: String?) async throws -> Step {
        var body: [String: Any] = [:]
        if let email, !email.isEmpty { body["email"] = email }
        let path: String
        switch method {
        case let .newCard(card, save):
            path = "process"
            body["pan"] = card.pan
            body["cvc"] = card.cvc
            body["expiry_month"] = card.expiryMonth
            body["expiry_year"] = card.expiryYear
            body["cardholder_name"] = card.holder
            body["save_card"] = save
        case let .card(card, cvc):
            switch card.kind {
            case .wallet:
                path = "process-wallet-card"
                body["card_id"] = card.id
            case .saved:
                path = "process-saved"
                body["saved_card_id"] = card.id
            }
            if let cvc, !cvc.isEmpty { body["cvc"] = cvc }
        case .balance:
            path = "process-wallet"
        }
        return try step(await call(path, body: body, needsPass: true))
    }

    func submitCode(_ code: String) async throws -> Step {
        try step(await call("otp", body: ["otp": code]))
    }

    /// Abandons the bank's step that waits for its code, so the payer can start over. Moves no money.
    func cancelCode() async {
        _ = try? await call("otp/cancel")
    }

    /// "Not you?": forget who was paying.
    func signOut() async {
        _ = try? await call("raisid/signout")
    }

    private func step(_ answer: Answer) throws -> Step {
        switch answer.json["status"] as? String {
        case "complete":
            let target = (answer.json["redirect"] as? String).flatMap { URLComponents(string: $0) }
            return .complete(order: target?.queryItems?.first { $0.name == "orderId" }?.value)
        case "otp_required":
            return .code(maskedCard: answer.json["masked_pan"] as? String)
        default:
            throw refusal(answer)
        }
    }

    // MARK: After the payment

    /// Has the bank named an outcome for the payment that is being confirmed?
    func isSettled(_ statusURL: URL) async -> Bool {
        guard CheckoutURL.isSameOrigin(statusURL, as: location.origin), let (data, _) = try? await send(URLRequest(url: statusURL)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["state"] as? String == "done"
    }

    /// E-mails the receipt: to the address the payment has, else to `address`. Returns the masked address it went (or had already gone) to.
    func emailReceipt(to address: String?) async throws -> String {
        var body: [String: Any] = [:]
        if let address, !address.isEmpty { body["email"] = address }
        let answer = try await call("receipt-email", body: body)
        let status = answer.json["status"] as? String
        guard status == "sent" || status == "already_sent" else { throw refusal(answer) }
        return answer.json["email"] as? String ?? ""
    }

    /// The PDF receipt, in a temporary file the caller removes.
    func downloadReceipt(_ address: URL, name: String) async throws -> URL {
        guard CheckoutURL.isSameOrigin(address, as: location.origin) else { throw Failure.unsupported }
        var request = URLRequest(url: address)
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard response.statusCode == 200, data.starts(with: Array("%PDF".utf8)) else { throw Failure.connection }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rais-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    /// The merchant's logo. From the checkout's own site with its session; from the merchant's own https address with a session that carries nothing.
    func image(_ address: URL) async -> UIImage? {
        let own = CheckoutURL.isSameOrigin(address, as: location.origin)
        guard own || address.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: address)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let loaded: (Data, URLResponse)?
        if own {
            loaded = (try? await send(request)).map { ($0.0, $0.1 as URLResponse) }
        } else {
            loaded = try? await URLSession(configuration: .ephemeral).data(for: request)
        }
        guard let (data, response) = loaded, (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000 else { return nil }
        return UIImage(data: data)
    }

    // MARK: The robot check

    /// Gets the pass ready before the payer needs it. Safe to call often.
    func warmUp() {
        guard needsPass else { return }
        Task { _ = await ensurePass() }
    }

    private func ensurePass() async -> Bool {
        if let passUntil, passUntil > Date().addingTimeInterval(30) { return true }
        if let passTask { return await passTask.value }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.obtainPass()
        }
        passTask = task
        let passed = await task.value
        passTask = nil
        return passed
    }

    private func obtainPass() async -> Bool {
        guard let challenge = try? await call("captcha/challenge"), let token = challenge.json["token"] as? String,
              let shape = challenge.json["challenge"] as? [String: Any], let count = shape["c"] as? Int, let size = shape["s"] as? Int,
              let difficulty = shape["d"] as? Int else { return false }
        let answers = await Task.detached(priority: .userInitiated) {
            ProofOfWork.solve(token: token, count: count, size: size, difficulty: difficulty)
        }.value
        guard let answers, !Task.isCancelled,
              let redeemed = try? await call("captcha/redeem", body: ["token": token, "solutions": answers]),
              redeemed.json["success"] as? Bool == true else { return false }
        let expires = (redeemed.json["expires"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        passUntil = expires ?? Date().addingTimeInterval(600)
        return true
    }

    // MARK: Plumbing

    private struct Answer {
        let status: Int
        let json: [String: Any]
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: location.pageURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    /// A POST of the payment's own endpoints. With `needsPass` the robot check is passed first, and passed again (once) when the server says
    /// the pass ran out.
    private func call(_ path: String, body: [String: Any]? = nil, needsPass wantsPass: Bool = false) async throws -> Answer {
        if wantsPass, needsPass { _ = await ensurePass() }
        var answer = try await post(path, body: body)
        if wantsPass, answer.json["code"] as? String == "captcha_required" {
            needsPass = true
            passUntil = nil
            if await ensurePass() { answer = try await post(path, body: body) }
        }
        return answer
    }

    private func post(_ path: String, body: [String: Any]?) async throws -> Answer {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        let (data, response) = try await send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Answer(status: response.statusCode, json: json)
    }

    private func refusal(_ answer: Answer) -> Refusal {
        Refusal(status: answer.status, code: answer.json["code"] as? String, message: answer.json["message"] as? String,
                field: answer.json["field"] as? String, retry: answer.json["retry"] as? Bool ?? false)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        ended.lock()
        let closed = isInvalidated
        ended.unlock()
        guard !closed else { throw Failure.connection }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.connection }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.connection
        }
    }
}

/// Redirects are answers here, not instructions: the address that identifies the payer redirects to a page this screen does not load, and a
/// payment call never redirects. Only a permanent move of the same request (307/308: the site sending a payer to its checkout host) is followed.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(response.statusCode == 307 || response.statusCode == 308 ? request : nil)
    }
}
