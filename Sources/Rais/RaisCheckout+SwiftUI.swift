import SwiftUI
import UIKit

extension View {
    /// Presents the Raïs checkout while `isPresented` is `true`, and sets it back to `false` when the checkout ends.
    ///
    /// ```swift
    /// Button("Pay") { showCheckout = true }
    ///     .raisCheckout(isPresented: $showCheckout, checkoutURL: checkoutURL) { result in
    ///         if case .completed(let payment) = result { /* ask your server about payment.id */ }
    ///     }
    /// ```
    ///
    /// Setting `isPresented` to `false` while the checkout is on screen closes it, as for any SwiftUI presentation; `onCompletion` is then
    /// called with what the payer had done so far (usually `.cancelled`).
    ///
    /// - Parameters:
    ///   - isPresented: whether the checkout is on screen.
    ///   - checkoutURL: the `checkout_url` your server got from `POST /payments`. Nothing is shown while it is `nil`.
    ///   - configuration: appearance and behavior.
    ///   - onCompletion: called once when the checkout has ended.
    public func raisCheckout(
        isPresented: Binding<Bool>,
        checkoutURL: URL?,
        configuration: RaisCheckout.Configuration = RaisCheckout.Configuration(),
        onCompletion: @escaping (RaisCheckout.Result) -> Void
    ) -> some View {
        modifier(RaisCheckoutModifier(isPresented: isPresented, checkoutURL: checkoutURL, configuration: configuration, onCompletion: onCompletion))
    }
}

/// What the modifier keeps between SwiftUI updates: the checkout on screen, and the screen to present it from.
private final class CheckoutHolder: ObservableObject {
    var checkout: RaisCheckout?
    /// The newest `checkoutURL` the modifier was given. The closures SwiftUI calls on a change can hold an older copy of the modifier, whose
    /// URL is still `nil` when `isPresented` and the URL turn up together; this is the one to read.
    var url: URL?
    weak var presenter: UIViewController?
    /// Watches the binding while the checkout is on screen (see `watch`).
    var watcher: Timer?

    func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }
}

/// The presentation is not driven by SwiftUI's updates alone: while a full-screen checkout covers the screen, the view that presented it is
/// out of the window, SwiftUI stops evaluating it (neither `updateUIViewController` nor `onChange` runs), and a binding turned off from code
/// would be ignored. So while the checkout is up its binding is also read on a short timer, and that is what closes it.
private struct RaisCheckoutModifier: ViewModifier {
    @Binding var isPresented: Bool
    let checkoutURL: URL?
    let configuration: RaisCheckout.Configuration
    let onCompletion: (RaisCheckout.Result) -> Void
    @StateObject private var holder = CheckoutHolder()

    func body(content: Content) -> some View {
        content
            .background(RaisCheckoutAnchor(holder: holder).frame(width: 0, height: 0))
            .onChange(of: isPresented) { show in sync(show) }
            .onChange(of: checkoutURL) { url in
                holder.url = url
                sync(isPresented)
            }
            .onAppear {
                holder.url = checkoutURL
                sync(isPresented)
            }
    }

    private func sync(_ show: Bool) {
        guard show else {
            if let checkout = holder.checkout {   // the binding was turned off from outside
                holder.checkout = nil
                checkout.dismiss()
            }
            return
        }
        guard holder.checkout == nil, let url = holder.url else { return }
        let checkout = RaisCheckout(checkoutURL: url, configuration: configuration)
        holder.checkout = checkout
        present(checkout, attempts: 8)
    }

    /// The anchor may not be in a window yet on the very first update (when `isPresented` starts as `true`): try again shortly.
    private func present(_ checkout: RaisCheckout, attempts: Int) {
        let holder = holder
        let binding = $isPresented
        let completion = onCompletion
        DispatchQueue.main.async {
            guard holder.checkout === checkout else { return }
            // The anchor sits in the view's own window. When it has none (the view is not on screen yet, or sits where SwiftUI gave it no
            // window) the app's front screen takes over, so the checkout is shown wherever the app is.
            let anchored = holder.presenter.flatMap { $0.viewIfLoaded?.window != nil ? $0 : nil }
            guard let presenter = anchored ?? (attempts <= 0 ? Self.frontScreen() : nil) else {
                if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { present(checkout, attempts: attempts - 1) }
                } else {
                    // never leave the modifier waiting on a checkout that cannot be shown: the next `isPresented = true` must be heard
                    holder.checkout = nil
                    binding.wrappedValue = false
                    completion(.failed(RaisCheckout.Failure(code: .cannotPresent, message: "There is no screen to present the checkout from.", paymentID: nil)))
                }
                return
            }
            checkout.present(from: presenter) { result in
                holder.stopWatching()
                holder.checkout = nil
                binding.wrappedValue = false
                completion(result)
            }
            watch(checkout, binding: binding)
        }
    }

    /// The root screen of the app's foreground window, for when the anchor has no window.
    private static func frontScreen() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.rootViewController
    }

    /// Closes the checkout when the binding goes false, whether or not SwiftUI is updating this view. Reading a binding outside an update
    /// is fine; the timer lives only while the checkout is on screen.
    private func watch(_ checkout: RaisCheckout, binding: Binding<Bool>) {
        let holder = holder
        holder.stopWatching()
        let timer = Timer(timeInterval: 0.15, repeats: true) { timer in
            guard holder.checkout === checkout else { return timer.invalidate() }   // it ended by itself
            if !binding.wrappedValue {
                timer.invalidate()
                holder.checkout = nil
                checkout.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holder.watcher = timer
    }
}

/// A zero-size screen in the view hierarchy that the checkout is presented from, so that SwiftUI and UIKit use the same presentation
/// (and the same keyboard handling) as `present(from:)`.
private struct RaisCheckoutAnchor: UIViewControllerRepresentable {
    let holder: CheckoutHolder

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        holder.presenter = controller
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
