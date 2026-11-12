import UIKit

/// The Raïs payment page, inside your app.
///
/// Your **server** creates the payment (`POST /payments` with your secret key) and returns its `checkout_url` to the app. The app never
/// holds a Raïs key. Then:
///
/// ```swift
/// let checkout = RaisCheckout(checkoutURL: checkoutURL, configuration: configuration)
/// checkout.present(from: self) { result in
///     switch result {
///     case .completed(let payment): // paid — now ask YOUR server for the order's real status
///     case .cancelled:              // the payer left
///     case .failed(let failure):    // declined, expired, or the page could not load
///     }
/// }
/// ```
///
/// In SwiftUI use the `raisCheckout(isPresented:checkoutURL:configuration:onCompletion:)` modifier.
public final class RaisCheckout {
    /// The version of this SDK.
    public static let version = CheckoutURL.version

    private let checkoutURL: URL
    private let configuration: Configuration
    private var controller: NativeCheckoutViewController?
    /// Keeps the checkout alive while it is on screen, as the system does for an alert controller.
    private var selfRetain: RaisCheckout?

    /// - Parameters:
    ///   - checkoutURL: the `checkout_url` of a payment your server created.
    ///   - configuration: appearance and behavior. The default is complete.
    public init(checkoutURL: URL, configuration: Configuration = Configuration()) {
        self.checkoutURL = checkoutURL
        self.configuration = configuration
    }

    /// Whether `url` can be shown as a checkout: an https address on `rais.app` (or one of `additionalTrustedHosts`), or a loopback
    /// address for local testing.
    public var isValid: Bool { CheckoutURL.isTrusted(checkoutURL, additionalHosts: configuration.additionalTrustedHosts) }

    /// Presents the checkout over `presenter` (the top-most presented screen is used when `presenter` is already presenting).
    /// `completion` is called once, on the main thread, after the checkout has been dismissed.
    public func present(from presenter: UIViewController, completion: @escaping (Result) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.present(from: presenter, completion: completion) }
            return
        }
        guard controller == nil else { return }   // already on screen
        guard isValid else {
            completion(.failed(Failure(code: .invalidURL, message: Strings.invalidURL(), paymentID: nil)))
            return
        }
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        guard top.viewIfLoaded?.window != nil else {
            completion(.failed(Failure(code: .cannotPresent, message: "The presenting view controller is not on screen.", paymentID: nil)))
            return
        }

        let screen = NativeCheckoutViewController(url: checkoutURL, configuration: configuration) { [weak self] result in
            self?.controller = nil
            self?.selfRetain = nil
            completion(result)
        }
        switch configuration.presentationStyle {
        case .fullScreen: screen.modalPresentationStyle = .fullScreen
        case .sheet: screen.modalPresentationStyle = .pageSheet
        }
        screen.isModalInPresentation = true   // a swipe must not end a payment: the close button does
        controller = screen
        selfRetain = self
        top.present(screen, animated: true)
    }

    /// Async version of `present(from:completion:)`: returns when the checkout has been dismissed.
    @MainActor
    @available(iOS 15.0, *)
    public func present(from presenter: UIViewController) async -> Result {
        await withCheckedContinuation { continuation in
            present(from: presenter) { continuation.resume(returning: $0) }
        }
    }

    /// Dismisses the checkout programmatically, as if the payer had closed it. The completion of `present` receives the outcome so far.
    public func dismiss() {
        controller?.finish()
    }
}
