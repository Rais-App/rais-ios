import UIKit

extension RaisCheckout {
    /// How the checkout looks and behaves. Every property has a default: `RaisCheckout.Configuration()` is a complete configuration.
    public struct Configuration {
        /// Colors, corner radius, font and light/dark mode of the checkout page.
        public var appearance = Appearance()

        /// The picture shown above the name of who is paid, instead of the logo that merchant set on its Raïs account. Optional: without it the
        /// checkout shows the account's own logo, or the first letter of its name when it has none. Square pictures look best.
        public var merchantLogo: UIImage?

        /// How the checkout is drawn: by the app's own controls (the default), or as the hosted web page.
        public var style: Style = .native

        /// The language of the page. `.automatic` (the default) lets Raïs choose from the payment and the device.
        /// The payer can still switch language on the page.
        public var language: Language = .automatic

        /// Full screen (the default), or a sheet that leaves the presenting screen visible above it.
        public var presentationStyle: PresentationStyle = .fullScreen

        /// Shows the SDK's close button over the top corner of the page. Leave it on unless you provide your own way out:
        /// a payer must always be able to leave the checkout.
        public var showsCloseButton = true

        /// The URL scheme of your app (for example `"myapp"`), when the payment's `success_url` / `cancel_url` are deep links into your app.
        /// The SDK then finishes with the payment result carried by that link instead of navigating to it. Optional: without it the
        /// result still arrives from the page itself.
        public var returnURLScheme: String?

        /// Hosts, besides `rais.app` and its subdomains, that may be loaded as the checkout (a staging environment, for example).
        /// Loopback addresses are always allowed so that you can test against a local server. Everything else is refused.
        public var additionalTrustedHosts: [String] = []

        public init() {}
    }

    /// The language of the checkout page.
    public enum Language: String, CaseIterable {
        case automatic
        case english = "en"
        case french = "fr"
        case arabic = "ar"

        /// The code sent to the page, or `nil` for `.automatic`.
        var code: String? { self == .automatic ? nil : rawValue }
    }

    /// How the checkout is drawn.
    public enum Style {
        /// Native controls: the payment, the card fields, the bank's code and the result are drawn by the SDK, and there is no robot check to
        /// tick. A payment whose card must be typed on the bank's own page is shown as that page, in the same screen.
        case native
        /// The hosted checkout page in a web view, as in version 1.
        case web
    }

    /// How the checkout is presented.
    public enum PresentationStyle {
        /// Covers the whole screen.
        case fullScreen
        /// A sheet: the screen below stays visible above the sheet, as for any page sheet.
        case sheet
    }
}
