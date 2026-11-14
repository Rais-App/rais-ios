import UIKit
import WebKit

/// The screen that shows the hosted checkout in a web view: the whole checkout when the app asks for `.web`, and otherwise the two payments the
/// native checkout hands over (a card typed on the bank's own page, a server without a native checkout).
///
/// **The keyboard.** The reason a hosted page jumps inside an app is a disagreement about who moves what when the keyboard opens: the
/// web view insets its own scroll view and pans its visual viewport, the page runs its own scrolling on top, and the two answer each other
/// for half a second. Here the native side decides, once: the web view is pinned *above* the keyboard (`keyboardLayoutGuide`), so the
/// keyboard never overlaps it, the web view has nothing to inset or pan, and the page is simply a shorter window onto which it scrolls
/// the focused field. Nothing moves except the keyboard's own animation.
final class WebCheckoutViewController: UIViewController {
    private let checkoutURL: URL
    private let configuration: RaisCheckout.Configuration
    private let completion: (RaisCheckout.Result) -> Void

    private var webView: WKWebView!
    private let contentController = WKUserContentController()
    private let closeButton = UIButton(type: .custom)
    private let closeDisc = UIView()
    private let closeGlyph = UIImageView()
    private var closeLeft: NSLayoutConstraint!
    private var closeRight: NSLayoutConstraint!
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failureView = LoadFailureView()

    /// The last outcome the page showed (a failed payment can still be retried, so only the last one counts).
    private var lastOutcome: (status: PageMessage.PageStatus, paymentID: String, reference: String?, orderNumber: String?)?
    private var finished = false
    /// The page could not be loaded and the payer is looking at the "Can't load" screen: closing it then is a failure, not a cancel.
    private var loadFailedShowing = false
    /// True while the checkout's own page is on screen: its scrolling is done by one container inside the page, never by the web view.
    private var pinsNativeScroll = false
    private var scrollPin: NSKeyValueObservation?
    private var seedCookies: [HTTPCookie]

    /// - Parameter cookies: what the native checkout already holds for this payment (who is paying), when this screen takes over from it.
    init(url: URL, configuration: RaisCheckout.Configuration, cookies: [HTTPCookie] = [], completion: @escaping (RaisCheckout.Result) -> Void) {
        self.seedCookies = cookies
        self.checkoutURL = url
        self.configuration = configuration
        self.completion = completion
        Strings.language = configuration.language.code
        super.init(nibName: nil, bundle: nil)
        switch configuration.appearance.colorScheme {
        case .light: overrideUserInterfaceStyle = .light
        case .dark: overrideUserInterfaceStyle = .dark
        case .automatic: break
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Appearance

    private var style: UIUserInterfaceStyle { configuration.appearance.effectiveStyle(for: traitCollection) }
    private var pageBackground: UIColor { configuration.appearance.backgroundColor(style: style) }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        var white: CGFloat = 0
        pageBackground.getWhite(&white, alpha: nil)
        return white < 0.5 ? .lightContent : .darkContent
    }

    // MARK: Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildWebView()
        buildChrome()
        applyColors()
        #if DEBUG
        if DebugProbe.enabled { probe.install(on: webView, controller: contentController) }
        #endif
        load()
    }

    #if DEBUG
    private let probe = DebugProbe()
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if DebugProbe.enabled, webView != nil { probe.layout(webView) }
    }
    #endif

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyColors()
        publishAppearance()
    }

    private func buildWebView() {
        let web = WKWebViewConfiguration()
        web.websiteDataStore = .nonPersistent()                       // nothing of a payment stays on the device
        web.defaultWebpagePreferences.allowsContentJavaScript = true
        web.allowsInlineMediaPlayback = true
        web.applicationNameForUserAgent = "RaisSDK/\(CheckoutURL.version) (iOS)"
        contentController.add(WeakMessageHandler(self), name: "rais")
        installBootstrapScript()
        web.userContentController = contentController

        let view = WKWebView(frame: .zero, configuration: web)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.scrollView.contentInsetAdjustmentBehavior = .never        // the page never gets an inset it did not ask for
        view.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        view.scrollView.keyboardDismissMode = .none
        #if DEBUG
        if #available(iOS 16.4, *) { view.isInspectable = true }       // Safari ▸ Develop, in debug builds only
        #endif
        view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(view)
        webView = view

        // WebKit sometimes scrolls its own scroll view to reveal the focused field before the page has been told that the window got shorter
        // (a 170 pt lift for 70 ms, then it drops back). The page never needs that scroll: it scrolls inside its own container. So while the
        // checkout page is shown the offset is put back to zero in the same turn of the run loop, before a frame is drawn with it.
        scrollPin = view.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            guard let self, self.pinsNativeScroll, scroll.contentOffset != .zero else { return }
            scroll.setContentOffset(.zero, animated: false)
        }

        // Top: below the status bar. Bottom: above the keyboard, or the home indicator when there is none. The container's own
        // background shows in those two strips, in the page's color, so the page looks edge to edge.
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func buildChrome() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        view.addSubview(spinner)

        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        failureView.onRetry = { [weak self] in self?.load() }
        view.addSubview(failureView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !configuration.showsCloseButton
        closeButton.accessibilityLabel = Strings.close()
        closeButton.accessibilityIdentifier = "rais.close"
        closeDisc.isUserInteractionEnabled = false
        closeDisc.translatesAutoresizingMaskIntoConstraints = false
        closeDisc.layer.cornerRadius = 16
        closeGlyph.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        closeGlyph.translatesAutoresizingMaskIntoConstraints = false
        closeGlyph.isUserInteractionEnabled = false
        closeButton.addSubview(closeDisc)
        closeButton.addSubview(closeGlyph)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // The close button sits at the start edge of the PAGE (left for English and French, right for Arabic), which is what the page
        // leaves room for: the page tells which in its "ready" message. Until then, the start edge of the app.
        closeLeft = closeButton.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 6)
        closeRight = closeButton.rightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.rightAnchor, constant: -6)
        placeCloseButton(rtl: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            closeDisc.widthAnchor.constraint(equalToConstant: 32),
            closeDisc.heightAnchor.constraint(equalToConstant: 32),
            closeDisc.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeDisc.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeGlyph.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeGlyph.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
    }

    private func placeCloseButton(rtl: Bool) {
        closeLeft.isActive = !rtl
        closeRight.isActive = rtl
    }

    private func applyColors() {
        let background = pageBackground
        view.backgroundColor = background
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.underPageBackgroundColor = background
        // The close button floats over a page that scrolls under it: an opaque disc (the page's color with a little ink in it) reads as a
        // button and hides what passes beneath, where a see-through one let the text show through.
        var white: CGFloat = 0
        background.getWhite(&white, alpha: nil)
        let ink: UIColor = white < 0.5 ? .white : .black
        closeDisc.backgroundColor = background.raisBlend(with: ink, amount: 0.10)
        closeGlyph.tintColor = ink.withAlphaComponent(0.62)
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: The page's configuration

    /// What the page receives before any of its own script runs. Always an explicit `light` or `dark`: "automatic" is decided here, so
    /// the page and the SDK can never disagree about the palette.
    private func pagePayload() -> [String: Any] {
        let payload: [String: Any] = [
            "platform": "ios",
            "version": CheckoutURL.version,
            "theme": style == .dark ? "dark" : "light",
            "chrome": configuration.showsCloseButton ? "native-close" : "none",
            "appearance": configuration.appearance.payload(style: style),
        ]
        return payload
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Only the checkout's own origin receives the configuration: the script does nothing on a bank's page.
    private func installBootstrapScript() {
        let origin = jsonString(["host": checkoutURL.host.map { host in
            checkoutURL.port.map { "\(host):\($0)" } ?? host
        } ?? ""])
        let source = """
        (function () {
          try {
            var allowed = \(origin).host;
            if (!allowed || window.location.host !== allowed) return;
            window.__RAIS_SDK__ = \(jsonString(pagePayload()));
          } catch (e) {}
        })();
        """
        contentController.removeAllUserScripts()
        contentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// The device went from light to dark (or back) while the checkout is open: the page already loaded learns it live, and the
    /// pages it loads next start in the right palette.
    private func publishAppearance() {
        installBootstrapScript()
        let call = "window.RaisSDK && window.RaisSDK.update(\(jsonString(pagePayload())));"
        webView.evaluateJavaScript(call, completionHandler: nil)
    }

    // MARK: Loading

    private func load() {
        loadFailedShowing = false
        failureView.isHidden = true
        spinner.startAnimating()
        guard let cookie = seedCookies.popLast() else {
            webView.load(URLRequest(url: firstURL))
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in self?.load() }
    }

    /// The page's text is written by the server, so a language the app asked for goes through the site's own language switch
    /// (`/lang/fr?next=/pay/…`): it keeps the choice in a cookie for the whole checkout, bank return included, then lands on the payment.
    private var firstURL: URL { CheckoutURL.entry(checkoutURL, languageCode: configuration.language.code) }

    // MARK: Leaving

    @objc private func closeTapped() { finish() }

    func finish(with forced: RaisCheckout.Result? = nil) {
        guard !finished else { return }
        finished = true
        let result = forced ?? makeResult()
        let done = completion
        if parent == nil, presentingViewController != nil {
            dismiss(animated: true) { done(result) }
        } else {
            done(result)   // inside the native checkout's screen: that screen leaves
        }
    }

    private func makeResult() -> RaisCheckout.Result {
        guard let outcome = lastOutcome else {
            // nothing was shown but the "Can't load the payment page" screen: tell the app that, not that the payer chose to leave
            return loadFailedShowing ? .failed(RaisCheckout.Failure(code: .loadFailed, message: Strings.loadFailedTitle(), paymentID: nil)) : .cancelled
        }
        switch outcome.status {
        case .paid:
            return .completed(RaisCheckout.Payment(id: outcome.paymentID, reference: outcome.reference, orderNumber: outcome.orderNumber))
        case .failed:
            return .failed(RaisCheckout.Failure(code: .declined, message: Strings.declined(), paymentID: outcome.paymentID))
        case .expired:
            return .failed(RaisCheckout.Failure(code: .expired, message: Strings.expired(), paymentID: outcome.paymentID))
        case .cancelled:
            return .cancelled
        }
    }

    /// The payment's `success_url` / `cancel_url` is a deep link into the app (`returnURLScheme`): its query carries the result.
    private func handleReturnLink(_ link: URL) {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let id = value("payment_id"), let raw = value("status"), let status = PageMessage.PageStatus(rawValue: raw),
           let parsed = PageMessage.parse(["type": "result", "status": status.rawValue, "paymentId": id,
                                           "reference": value("reference") as Any, "orderNumber": value("order_number") as Any]),
           case let .result(status, paymentID, reference, orderNumber) = parsed {
            lastOutcome = (status, paymentID, reference, orderNumber)
        }
        finish()
    }
}

// MARK: - Navigation

extension WebCheckoutViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.cancel) }
        let scheme = target.scheme?.lowercased() ?? ""

        if let own = configuration.returnURLScheme?.lowercased(), !own.isEmpty, scheme == own {
            decisionHandler(.cancel)
            handleReturnLink(target)
            return
        }

        switch scheme {
        case "http", "https":
            // A link on the checkout page that leads elsewhere (the terms, the Raïs site) opens in the system browser: inside this
            // web view the payer would have no way back. Bank pages and 3-D Secure redirects are never "links on the checkout page".
            let fromCheckout = CheckoutURL.isSameOrigin(action.sourceFrame.request.url, as: checkoutURL)
            if action.navigationType == .linkActivated, fromCheckout, !CheckoutURL.isSameOrigin(target, as: checkoutURL) {
                decisionHandler(.cancel)
                if scheme == "https" { UIApplication.shared.open(target) }
                return
            }
            // `target=_blank` and `window.open` (the bank's 3-D Secure window) stay in this same web view.
            if action.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: target))
                return
            }
            decisionHandler(.allow)
        case "about", "blob", "data":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)   // tel:, mailto:, app links: never opened by a payment page
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The checkout scrolls inside its own container, so the web view's scroll view stays still. A bank's page has no such container:
        // it gets the native scroll view back.
        let ours = CheckoutURL.isSameOrigin(webView.url, as: checkoutURL)
        pinsNativeScroll = false   // until this page says it is the checkout (its "ready" message)
        webView.scrollView.isScrollEnabled = !ours
        webView.scrollView.bounces = !ours
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()   // iOS reclaimed the page's process while the app was in the background
    }

    private func loadFailed(_ error: Error) {
        spinner.stopAnimating()
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 { return }   // a redirect or a policy decision, not a failure
        loadFailedShowing = true
        failureView.isHidden = false
    }
}

// MARK: - The page's messages

extension WebCheckoutViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the checkout page itself may talk to the app: not a bank's page, not a frame inside a page.
        guard message.name == "rais", message.frameInfo.isMainFrame, isCheckoutOrigin(message.frameInfo.securityOrigin),
              let parsed = PageMessage.parse(message.body) else { return }
        switch parsed {
        case let .ready(page, rtl):
            loadFailedShowing = false
            spinner.stopAnimating()
            placeCloseButton(rtl: rtl)
            pinsNativeScroll = true   // the page that says so scrolls inside itself
            if page == "pay" { lastOutcome = nil }   // the payer is paying (again): an earlier outcome no longer counts
        case let .result(status, paymentID, reference, orderNumber):
            lastOutcome = (status, paymentID, reference, orderNumber)
        case .done, .close:
            finish()
        }
    }

    private func isCheckoutOrigin(_ origin: WKSecurityOrigin) -> Bool {
        let scheme = origin.protocol.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        return scheme == checkoutURL.scheme?.lowercased()
            && origin.host.lowercased() == checkoutURL.host?.lowercased()
            && (origin.port == 0 ? defaultPort : origin.port) == (checkoutURL.port ?? (checkoutURL.scheme?.lowercased() == "https" ? 443 : 80))
    }
}

// MARK: - Windows and alerts

extension WebCheckoutViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, action.targetFrame == nil { webView.load(URLRequest(url: url)) }   // never a second web view
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: Strings.close(), style: .cancel) { _ in completionHandler(false) })
        present(alert, animated: true)
    }
}

/// `WKUserContentController` keeps its handlers alive; this keeps the screen from being kept alive by it.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// "Can't load the payment page" with a retry button, over the web view.
private final class LoadFailureView: UIView {
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let title = UILabel()
        title.text = Strings.loadFailedTitle()
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        let body = UILabel()
        body.text = Strings.loadFailedBody()
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0
        body.adjustsFontForContentSizeCategory = true
        var configuration = UIButton.Configuration.filled()
        configuration.title = Strings.retry()
        configuration.cornerStyle = .medium
        let retry = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onRetry?() })
        retry.accessibilityIdentifier = "rais.retry"
        let stack = UIStackView(arrangedSubviews: [title, body, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
