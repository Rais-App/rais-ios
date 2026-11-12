import Foundation

/// Which addresses may be shown as a checkout, and which hosts may talk to the app through the bridge.
///
/// The bridge is a door from a web page into the app. It opens for the checkout page only, never for a bank's 3-D Secure page that the
/// same web view navigates to on the way, so the rule is the same for both: the host the SDK was given, and only if it is trusted.
enum CheckoutURL {
    static let version = "1.0.0"

    /// `rais.app` and its subdomains, plus loopback addresses for local testing, plus what the integrator added.
    static func isTrusted(_ url: URL, additionalHosts: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if isLoopback(host) { return scheme == "http" || scheme == "https" }
        guard scheme == "https" else { return false }
        if host == "rais.app" || host.hasSuffix(".rais.app") { return true }
        return additionalHosts.contains { extra in
            let trusted = extra.lowercased()
            return host == trusted
        }
    }

    /// The address to load first. Without a language it is the checkout itself; with one it is the site's own language switch
    /// (`/lang/fr?next=/pay/…`), which keeps the choice in a cookie for the whole checkout (the bank's return included) and then lands on
    /// the same payment.
    static func entry(_ checkout: URL, languageCode: String?) -> URL {
        guard let code = languageCode, ["en", "fr", "ar"].contains(code),
              var parts = URLComponents(url: checkout, resolvingAgainstBaseURL: false) else { return checkout }
        let next = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        // as a query value "/", "?", "=" and "&" must all be escaped: only letters and digits stay as they are
        let escaped = next.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? next
        parts.percentEncodedPath = "/lang/\(code)"
        parts.percentEncodedQuery = "next=\(escaped)"
        return parts.url ?? checkout
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Whether a page address belongs to the checkout the SDK opened: same scheme, host and port.
    static func isSameOrigin(_ candidate: URL?, as origin: URL) -> Bool {
        guard let candidate else { return false }
        return candidate.scheme?.lowercased() == origin.scheme?.lowercased()
            && candidate.host?.lowercased() == origin.host?.lowercased()
            && (candidate.port ?? defaultPort(candidate)) == (origin.port ?? defaultPort(origin))
    }

    private static func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }
}

/// What the page tells the app. Messages come from the checkout page only (see `CheckoutURL`), and are validated field by field.
enum PageMessage: Equatable {
    /// The page is on screen and ready. `page` is `pay` for the payment form, `result` for a page that says how a payment ended; `rtl` is
    /// whether the page reads right to left (Arabic), whatever the language of the app: the close button goes to the page's start edge.
    case ready(page: String, rtl: Bool)
    /// A payment reached an end the page shows to the payer: paid, failed or cancelled. The payer may still retry a failed one.
    case result(status: PageStatus, paymentID: String, reference: String?, orderNumber: String?)
    /// The payer pressed the page's own "Done" / "Return" button: leave the checkout with the last result.
    case done
    /// The payer pressed the page's own back link: leave the checkout.
    case close

    enum PageStatus: String { case paid, failed, cancelled, expired }

    static func parse(_ body: Any) -> PageMessage? {
        guard let dictionary = body as? [String: Any], let type = dictionary["type"] as? String else { return nil }
        switch type {
        case "ready": return .ready(page: (dictionary["page"] as? String) == "pay" ? "pay" : "result", rtl: (dictionary["dir"] as? String) == "rtl")
        case "done": return .done
        case "close": return .close
        case "result":
            guard let raw = dictionary["status"] as? String, let status = PageStatus(rawValue: raw),
                  let id = dictionary["paymentId"] as? String, isUUID(id) else { return nil }
            return .result(status: status, paymentID: id.lowercased(),
                           reference: bounded(dictionary["reference"]), orderNumber: bounded(dictionary["orderNumber"]))
        default: return nil
        }
    }

    private static func isUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil && value.count == 36 }

    private static func bounded(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= 200 else { return nil }
        return text
    }
}

/// The words the SDK itself shows (the page has its own): loaded by `Bundle.module`, so they follow the device language.
enum Strings {
    static func close() -> String { text("close", "Close") }
    static func loadFailedTitle() -> String { text("load_failed_title", "Can't load the payment page") }
    static func loadFailedBody() -> String { text("load_failed_body", "Check your connection and try again.") }
    static func retry() -> String { text("retry", "Try again") }
    static func declined() -> String { text("declined", "The payment was declined.") }
    static func expired() -> String { text("expired", "The payment expired.") }
    static func invalidURL() -> String { text("invalid_url", "This is not a valid Raïs checkout address.") }

    private static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: resources, value: fallback, comment: "")
    }

    private final class BundleToken {}

    /// Swift Package Manager builds a resource bundle named by `Bundle.module`; CocoaPods builds `RaisResources.bundle` inside the framework.
    static let resources: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let framework = Bundle(for: BundleToken.self)
        if let url = framework.url(forResource: "RaisResources", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return framework
        #endif
    }()
}
