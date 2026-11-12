import QuickLook
import UIKit

/// The checkout, drawn by the app: the payment and the ways to pay it, the bank's code, and what became of the payment.
///
/// The server keeps every rule and every word (`GET /pay/{id}/sheet` says what to show, the page's own calls pay). This screen reads the
/// checkout, draws it with native controls, and reports how it ended. Two payments are not drawn here and go to the web checkout instead,
/// inside this same screen: one whose card must be typed on the bank's own page, and one on a server that has no native checkout yet.
final class NativeCheckoutViewController: UIViewController {
    private let checkoutURL: URL
    private let configuration: RaisCheckout.Configuration
    private let completion: (RaisCheckout.Result) -> Void
    private let theme: SheetTheme
    private var api: CheckoutAPI?

    // chrome
    private let closeButton = UIButton(type: .custom)
    private let closeDisc = UIView()
    private let closeGlyph = UIImageView()
    private let chipSlot = UIStackView()
    private let scroll = UIScrollView()
    private let stage = UIStackView()
    private let bar = UIView()
    private let barLine = UIView()
    private let barStack = UIStackView()
    private let notice: NoticeView
    private let primary: SheetButton
    private let secondary: SheetButton
    private let assurance = UIStackView()
    private let assuranceLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failure = UIStackView()
    private var web: WebCheckoutViewController?

    // state
    private enum Phase { case loading, pay, code, outcome, failed, web }
    private var phase = Phase.loading
    private var sheet: Sheet?
    private var context: SheetContext?
    private var payView: PayView?
    private var codeView: CodeView?
    private var outcomeView: OutcomeView?
    private var retry: (() -> Void)?
    private var isBusy = false
    private var finished = false
    private var loadFailedShowing = false
    /// The last outcome the payer was shown (a failed payment can still be retried, so only the last one counts).
    private var lastOutcome: Sheet.Outcome.Reported?
    private var sessionUntil: Date?
    private var sessionTask: Task<Void, Error>?
    private var lastPrepare = Date.distantPast
    private var poller: Task<Void, Never>?
    private var leftForApp = false
    private var receiptFile: URL?
    private var keyboardUp = false
    private var secondaryWanted = false
    /// What `applyDirection` set, so that it can set it again the other way when the language of the checkout changes.
    private var directed = UISemanticContentAttribute.unspecified
    private let aligned = NSHashTable<UILabel>.weakObjects()

    init(url: URL, configuration: RaisCheckout.Configuration, completion: @escaping (RaisCheckout.Result) -> Void) {
        checkoutURL = url
        self.configuration = configuration
        self.completion = completion
        theme = SheetTheme(configuration.appearance)
        notice = NoticeView(theme: theme, tone: .danger)
        primary = SheetButton(theme: theme, kind: .primary, title: "")
        secondary = SheetButton(theme: theme, kind: .plain, title: "")
        super.init(nibName: nil, bundle: nil)
        switch configuration.appearance.colorScheme {
        case .light: overrideUserInterfaceStyle = .light
        case .dark: overrideUserInterfaceStyle = .dark
        case .automatic: break
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        poller?.cancel()
        if let receiptFile { try? FileManager.default.removeItem(at: receiptFile.deletingLastPathComponent()) }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if let web { return web.preferredStatusBarStyle }
        var white: CGFloat = 0
        theme.background.resolvedColor(with: traitCollection).getWhite(&white, alpha: nil)
        return white < 0.5 ? .lightContent : .darkContent
    }

    // MARK: Building

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.background
        buildStage()
        buildBar()
        buildChrome()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cameBack), name: UIApplication.didBecomeActiveNotification, object: nil)
        start()
    }

    private func buildStage() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.showsVerticalScrollIndicator = false
        scroll.delaysContentTouches = false
        view.addSubview(scroll)
        stage.axis = .vertical
        stage.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stage)
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = theme.background
        view.addSubview(bar)

        // Readable on an iPad or in landscape too: the content never grows wider than a phone's.
        let width = stage.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            // under the close button's row: what scrolls never passes behind it
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 54),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            stage.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stage.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stage.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stage.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            width,
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // above the keyboard, or above the home indicator when there is none: nothing is ever under the keyboard
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func buildBar() {
        barLine.backgroundColor = theme.line
        barLine.translatesAutoresizingMaskIntoConstraints = false
        barLine.alpha = 0
        bar.addSubview(barLine)

        primary.accessibilityIdentifier = "rais.primary"
        primary.onTap { [weak self] in self?.primaryTapped() }
        secondary.accessibilityIdentifier = "rais.secondary"
        secondary.onTap { [weak self] in self?.secondaryTapped() }
        notice.isHidden = true

        let lock = UIImageView(image: Glyph.image("lock.fill", size: 10))
        lock.tintColor = theme.secondary
        lock.setContentHuggingPriority(.required, for: .horizontal)
        assuranceLabel.font = theme.font(12, .regular, style: .caption1)
        assuranceLabel.textColor = theme.secondary
        assuranceLabel.adjustsFontForContentSizeCategory = true
        assuranceLabel.numberOfLines = 2
        let line = UIStackView(arrangedSubviews: [lock, assuranceLabel])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = 5
        assurance.axis = .vertical
        assurance.alignment = .center
        assurance.addArrangedSubview(line)

        barStack.axis = .vertical
        barStack.spacing = 10
        barStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [notice, primary, secondary, assurance] as [UIView] { barStack.addArrangedSubview(view) }
        barStack.setCustomSpacing(4, after: primary)
        bar.addSubview(barStack)
        let width = barStack.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -40)
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            barLine.topAnchor.constraint(equalTo: bar.topAnchor),
            barLine.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            barLine.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            barLine.heightAnchor.constraint(equalToConstant: 1),
            barStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            barStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            barStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            barStack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            width,
        ])
        scroll.delegate = self
        bar.isHidden = true
    }

    private func buildChrome() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !configuration.showsCloseButton
        closeButton.accessibilityLabel = Strings.close()
        closeButton.accessibilityIdentifier = "rais.close"
        closeDisc.isUserInteractionEnabled = false
        closeDisc.translatesAutoresizingMaskIntoConstraints = false
        closeDisc.layer.cornerRadius = 16
        closeDisc.backgroundColor = theme.surface
        closeGlyph.image = Glyph.image("xmark", size: 12, weight: .bold)
        closeGlyph.tintColor = theme.secondary
        closeGlyph.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addSubview(closeDisc)
        closeButton.addSubview(closeGlyph)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        chipSlot.axis = .horizontal
        chipSlot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipSlot)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = theme.secondary
        view.addSubview(spinner)

        let title = UILabel()
        title.text = Strings.loadFailedTitle()
        title.font = theme.font(17, .semibold, style: .headline)
        title.textColor = theme.text
        let body = UILabel()
        body.text = Strings.loadFailedBody()
        body.font = theme.font(15, .regular, style: .subheadline)
        body.textColor = theme.secondary
        for label in [title, body] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let again = SheetButton(theme: theme, kind: .secondary, title: Strings.retry(), symbol: "arrow.clockwise")
        again.accessibilityIdentifier = "rais.retry"
        again.onTap { [weak self] in self?.retry?() }
        again.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        failure.axis = .vertical
        failure.alignment = .center
        failure.spacing = 8
        failure.translatesAutoresizingMaskIntoConstraints = false
        failure.isHidden = true
        for view in [IconDisc(theme: theme, symbol: "wifi.slash", color: theme.secondary), title, body, again] as [UIView] { failure.addArrangedSubview(view) }
        failure.setCustomSpacing(16, after: failure.arrangedSubviews[0])
        failure.setCustomSpacing(20, after: body)
        view.addSubview(failure)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            closeDisc.widthAnchor.constraint(equalToConstant: 32),
            closeDisc.heightAnchor.constraint(equalToConstant: 32),
            closeDisc.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeDisc.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeGlyph.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeGlyph.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            chipSlot.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            chipSlot.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            failure.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: Reading the checkout

    private func start() {
        guard configuration.style == .native, let location = CheckoutAPI.Location(checkoutURL) else {
            showWeb(checkoutURL, cookies: [])
            return
        }
        let api = CheckoutAPI(checkoutURL: checkoutURL, location: location, languageCode: configuration.language.code)
        self.api = api
        load { try await api.open() }
    }

    private enum Reading {
        /// The screen shows that it is reading.
        case visibly
        /// The page stays as it is, its button busy, until the answer is there (the outcome of a payment that was just sent).
        case behindThePage
        /// The page stays and is replaced only if there is an answer: nothing is said when there is none.
        case silently
    }

    /// Reads the checkout with `read` and shows what it says. A lost connection shows "Can't load" with a way to ask again, the same question.
    private func load(_ reading: Reading = .visibly, _ read: @escaping () async throws -> Sheet) {
        poller?.cancel()
        if reading == .visibly { show(.loading) }
        Task { [weak self] in
            do {
                let sheet = try await read()
                guard let self, !self.finished else { return }
                self.render(sheet)
            } catch CheckoutAPI.Failure.unsupported {
                guard let self, !self.finished, let api = self.api else { return }
                self.showWeb(api.location.isPlain ? self.checkoutURL : api.location.pageURL, cookies: api.cookies)
            } catch {
                guard let self, !self.finished, reading != .silently else { return }
                self.setBusy(false)
                self.retry = { [weak self] in self?.load(.visibly, read) }
                self.show(.failed)
            }
        }
    }

    private func reload(_ reading: Reading = .visibly) {
        guard let api else { return }
        load(reading) { try await api.sheet() }
    }

    private func render(_ sheet: Sheet) {
        self.sheet = sheet
        let context = SheetContext(theme: theme, words: Words(table: sheet.text), rtl: sheet.rtl, sandbox: sheet.sandbox)
        self.context = context
        setBusy(false)
        showNotice(nil)

        chipSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if sheet.sandbox { chipSlot.addArrangedSubview(Chip(theme: theme, text: context.words["test.mark"], color: theme.warning)) }

        switch sheet.state {
        case .pay:
            guard let pay = sheet.pay, let payment = sheet.payment, pay.mode != "raw", let api else {
                // the card is typed on the bank's own page: that page is a web page
                if let api { showWeb(api.location.pageURL, cookies: api.cookies) }
                return
            }
            lastOutcome = nil
            api.warmUp()
            let canOpenApp = pay.appURL.map { UIApplication.shared.canOpenURL($0) } ?? false
            let page = PayView(context: context, sheet: sheet, payment: payment, pay: pay, canOpenApp: canOpenApp)
            page.onChoice = { [weak self, weak page] in if let page { self?.primary.title = page.buttonTitle } }
            page.onCardEditing = { [weak self] in self?.prepareSession() }
            page.onFocus = { [weak self] view in self?.reveal(view) }
            page.onResize = { [weak self] in self?.view.layoutIfNeeded() }
            page.onSignOut = { [weak self] in self?.signOut() }
            page.onOpen = { url in UIApplication.shared.open(url) }
            page.onOpenApp = { [weak self] url in
                self?.leftForApp = true
                UIApplication.shared.open(url)
            }
            payView = page
            primary.title = page.buttonTitle
            primary.symbol = "lock.fill"
            primary.isEnabled = true
            secondaryWanted = false
            assuranceLabel.text = context.words["pay.encrypted"]
            show(.pay, page: page)
            if let logo = sheet.merchant?.logoURL {
                Task { [weak page] in if let image = await api.image(logo) { page?.show(logo: image) } }
            }
        case .result:
            guard let result = sheet.result else { return showMissing(sheet) }
            lastOutcome = result.outcome
            let page = OutcomeView(context: context, sheet: sheet, result: result)
            page.onViewReceipt = { [weak self] in self?.openReceipt() }
            page.onEmailReceipt = { [weak self] address in self?.emailReceipt(to: address) }
            page.onContact = { address in if let url = URL(string: "mailto:\(address)") { UIApplication.shared.open(url) } }
            page.onFocus = { [weak self] view in self?.reveal(view) }
            page.onResize = { [weak self] in self?.view.layoutIfNeeded() }
            outcomeView = page
            if result.confirming != nil {
                primary.title = context.words["confirming.check_again"]
                primary.symbol = "arrow.clockwise"
                secondaryWanted = false
            } else if result.retry {
                primary.title = context.words["result.try_again"]
                primary.symbol = "creditcard"
                secondary.title = context.words["js.sdk_done"]
                secondaryWanted = true
            } else {
                primary.title = context.words["js.sdk_done"]
                primary.symbol = nil
                secondaryWanted = false
            }
            primary.isEnabled = true
            show(.outcome, page: page)
            switch result.tone {
            case .ok: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .bad: UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .neutral: break
            }
            if let confirming = result.confirming { poll(confirming) }
        case .notFound:
            showMissing(sheet)
        }
    }

    /// A link that names no payment: the server's two sentences, and the way out.
    private func showMissing(_ sheet: Sheet) {
        guard let context else { return }
        let title = UILabel()
        title.text = sheet.title ?? Strings.invalidURL()
        title.font = theme.font(22, .bold, style: .title2)
        title.textColor = theme.text
        let lead = UILabel()
        lead.text = sheet.lead
        lead.font = theme.font(15, .regular, style: .subheadline)
        lead.textColor = theme.secondary
        for label in [title, lead] {
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        let column = UIStackView(arrangedSubviews: [IconDisc(theme: theme, symbol: "exclamationmark", color: theme.secondary), title, lead])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        column.setCustomSpacing(16, after: column.arrangedSubviews[0])
        primary.title = context.words["js.sdk_done"].isEmpty ? Strings.close() : context.words["js.sdk_done"]
        primary.symbol = nil
        secondaryWanted = false
        show(.outcome, page: column)
    }

    // MARK: Showing a phase

    private func show(_ new: Phase, page: UIView? = nil) {
        phase = new
        loadFailedShowing = new == .failed
        failure.isHidden = new != .failed
        new == .loading ? spinner.startAnimating() : spinner.stopAnimating()
        if new != .pay { payView = nil }
        if new != .code { codeView = nil }
        if new != .outcome { outcomeView = nil }

        view.endEditing(true)
        stage.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bar.isHidden = page == nil
        guard let page else { return }
        stage.addArrangedSubview(page)
        applyDirection()
        updateBar()
        scroll.setContentOffset(.zero, animated: false)
        view.layoutIfNeeded()
        scrollViewDidScroll(scroll)
        // the new page settles in: a short rise, so a change of step reads as one
        for part in [page, bar] as [UIView] {
            part.alpha = 0
            part.transform = CGAffineTransform(translationX: 0, y: part === bar ? 0 : 10)
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            page.alpha = 1
            page.transform = .identity
            self.bar.alpha = 1
        } completion: { _ in
            UIAccessibility.post(notification: .screenChanged, argument: page)
        }
    }

    /// The words may read the other way than the app (an Arabic checkout in a French app): the screen follows the words.
    private func applyDirection() {
        guard let context else { return }
        let attribute: UISemanticContentAttribute = context.rtl ? .forceRightToLeft : .forceLeftToRight
        let alignment: NSTextAlignment = context.rtl ? .right : .left
        func walk(_ view: UIView) {
            if view.semanticContentAttribute == .unspecified || view.semanticContentAttribute == directed { view.semanticContentAttribute = attribute }
            if let label = view as? UILabel, label.textAlignment == .natural || aligned.contains(label) {
                label.textAlignment = alignment
                aligned.add(label)
            }
            // a card number or an address reads left to right in every language, and still sits under its caption
            if let field = view as? UITextField, field.semanticContentAttribute == .forceLeftToRight, attribute == .forceRightToLeft || directed == .forceRightToLeft {
                field.textAlignment = alignment
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        directed = attribute
    }

    private func showNotice(_ text: String?) {
        let hidden = text == nil
        if !hidden {
            notice.text = text
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        guard notice.isHidden != hidden else { return }
        UIView.animate(withDuration: 0.22) {
            self.notice.isHidden = hidden
            self.notice.alpha = hidden ? 0 : 1
            self.view.layoutIfNeeded()
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        primary.isLoading = busy
        secondary.isEnabled = !busy
        closeButton.isEnabled = !busy
        closeButton.alpha = busy ? 0.4 : 1
        payView?.isBusy = busy
        codeView?.code.isLocked = busy
    }

    // MARK: Keyboard and scrolling

    @objc private func keyboardChanged(_ note: Notification) {
        keyboardUp = note.name == UIResponder.keyboardWillShowNotification
        UIView.animate(withDuration: 0.25) {
            self.updateBar()
            self.view.layoutIfNeeded()
        }
    }

    /// What the bar shows under its button. With the keyboard up it keeps only what acts: the room goes to the fields.
    private func updateBar() {
        let showsAssurance = phase == .pay && !keyboardUp
        assurance.isHidden = !showsAssurance
        assurance.alpha = showsAssurance ? 1 : 0
        secondary.isHidden = !secondaryWanted
    }

    /// Brings a field into view, with what is said under it: its bottom first, then its top if the field is taller than the room.
    private func reveal(_ target: UIView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, target.window != nil else { return }
            self.view.layoutIfNeeded()
            let frame = target.convert(target.bounds, to: self.scroll).insetBy(dx: 0, dy: -16)
            let visible = self.scroll.bounds
            var offset = self.scroll.contentOffset.y
            if frame.maxY > visible.maxY { offset += frame.maxY - visible.maxY }
            if frame.minY < offset { offset = frame.minY }
            let limit = max(0, self.scroll.contentSize.height - visible.height)
            offset = min(max(0, offset), limit)
            guard abs(offset - self.scroll.contentOffset.y) > 0.5 else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.scroll.contentOffset.y = offset
            }
        }
    }

    @objc private func backgroundTapped() { view.endEditing(true) }

    // MARK: Paying

    private func primaryTapped() {
        guard !isBusy else { return }
        switch phase {
        case .pay: submitPayment()
        case .code: submitCode()
        case .outcome:
            if let confirming = sheet?.result?.confirming, let api {
                load { try await api.sheet(at: confirming.resultURL) }
            } else if sheet?.result?.retry == true {
                reload()
            } else {
                finish()
            }
        default: break
        }
    }

    private func secondaryTapped() {
        guard !isBusy else { return }
        switch phase {
        case .code: cancelCode()
        case .outcome: finish()
        default: break
        }
    }

    private func submitPayment(secondTry: Bool = false) {
        guard let api, let payView, let context, let submission = payView.collect() else { return }
        showNotice(nil)
        setBusy(true)
        Task { [weak self] in
            do {
                if case .newCard = submission.method { try await self?.ensureSession() }
                let step = try await api.pay(submission.method, email: submission.email)
                self?.advance(step)
            } catch let refusal as CheckoutAPI.Refusal {
                guard let self, !self.finished else { return }
                let words = context.words
                switch refusal.code {
                case "awaiting_otp" where !secondTry:
                    // an earlier attempt still waits for a code this screen can no longer give: it is dropped, and this one goes on
                    await api.cancelCode()
                    self.setBusy(false)
                    self.submitPayment(secondTry: true)
                case "session_over" where !secondTry, "not_registered" where !secondTry:
                    self.sessionUntil = nil
                    self.setBusy(false)
                    self.submitPayment(secondTry: true)
                case "already_paid", "not_payable", "expired", "confirming":
                    self.reload()   // the payment is no longer what this screen shows: show what it is
                case "cvc_required":
                    self.setBusy(false)
                    if !payView.askForSavedCVC() { self.showNotice(words.describing(refusal)) }
                case "cvc_invalid":
                    self.setBusy(false)
                    if !payView.showSavedCVCProblem(words.describing(refusal)) { self.showNotice(words.describing(refusal)) }
                default:
                    self.setBusy(false)
                    if refusal.field == "email", payView.showEmailProblem(words.describing(refusal)) { return }
                    if refusal.code == "session_over" || refusal.code == "not_registered" { self.sessionUntil = nil }
                    self.showNotice(words.describing(refusal))
                }
            } catch {
                guard let self, !self.finished else { return }
                self.setBusy(false)
                self.showNotice(context.words["js.connection"])
            }
        }
    }

    private func advance(_ step: CheckoutAPI.Step) {
        guard !finished, let api, let context else { return }
        switch step {
        case .complete(let order):
            sessionUntil = nil
            // the button keeps spinning until the outcome is read: the payer never sees the form again in between
            load(.behindThePage) { try await api.sheet(order: order, fresh: order == nil) }
        case .code(let masked):
            let page = CodeView(context: context, maskedCard: masked, length: sheet?.pay?.otpLength ?? 6)
            page.code.onChange = { [weak self, weak page] in
                guard let self, let page else { return }
                page.setProblem(nil)
                self.primary.isEnabled = page.code.isComplete
            }
            codeView = page
            setBusy(false)
            showNotice(nil)
            primary.title = context.words["otp.cta"]
            primary.symbol = "lock.fill"
            primary.isEnabled = false
            secondary.title = context.words["otp.cancel"]
            secondaryWanted = true
            show(.code, page: page)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak page] in page?.code.focus() }
        }
    }

    /// A session with the bank for a typed card: asked for when the payer starts on the card, renewed when it ran out.
    private func ensureSession() async throws {
        if let sessionUntil, sessionUntil > Date().addingTimeInterval(10) { return }
        if let sessionTask { return try await sessionTask.value }
        guard let api else { return }
        let seconds = sheet?.pay?.sessionSeconds ?? 570
        let task = Task { [weak self] in
            try await api.register()
            self?.sessionUntil = Date().addingTimeInterval(seconds)
        }
        sessionTask = task
        defer { sessionTask = nil }
        try await task.value
    }

    private func prepareSession() {
        guard phase == .pay, !isBusy, Date().timeIntervalSince(lastPrepare) > 15 else { return }
        lastPrepare = Date()
        Task { [weak self] in try? await self?.ensureSession() }   // said again when the payer pays
    }

    private func signOut() {
        guard let api, !isBusy else { return }
        show(.loading)
        Task { [weak self] in
            await api.signOut()
            self?.reload()
        }
    }

    // MARK: The bank's code

    private func submitCode() {
        guard let api, let codeView, let context, codeView.code.isComplete else { return }
        showNotice(nil)
        setBusy(true)
        let code = codeView.code.code
        Task { [weak self] in
            do {
                let step = try await api.submitCode(code)
                self?.advance(step)
            } catch let refusal as CheckoutAPI.Refusal {
                guard let self, !self.finished else { return }
                self.setBusy(false)
                if refusal.retry {
                    // the bank refused this code but its step goes on
                    codeView.code.code = ""
                    codeView.setProblem(context.words["js.otp_wrong"])
                    self.primary.isEnabled = false
                    codeView.code.focus()
                } else if refusal.status == 429 || refusal.code == "in_progress" || refusal.code == "gateway_unreachable" {
                    self.showNotice(context.words.describing(refusal))   // the step is still there: the same code can be sent again
                } else {
                    // the step is over (refused, expired): back to the ways to pay, with the reason
                    let reason = context.words.describing(refusal)
                    self.returnToPayment(saying: reason)
                }
            } catch {
                guard let self, !self.finished else { return }
                self.setBusy(false)
                self.showNotice(context.words["js.connection"])
            }
        }
    }

    private func cancelCode() {
        guard let api else { return }
        setBusy(true)
        Task { [weak self] in
            await api.cancelCode()
            self?.sessionUntil = nil
            self?.reload()
        }
    }

    private func returnToPayment(saying reason: String) {
        guard let api else { return }
        sessionUntil = nil
        show(.loading)
        Task { [weak self] in
            do {
                let sheet = try await api.sheet()
                guard let self, !self.finished else { return }
                self.render(sheet)
                if self.phase == .pay { self.showNotice(reason) }
            } catch {
                self?.reload()
            }
        }
    }

    // MARK: After the payment

    /// The bank has named no outcome yet: ask every few seconds, for a few minutes, and show the outcome as soon as there is one.
    private func poll(_ confirming: Sheet.Outcome.Confirming) {
        poller?.cancel()
        guard let api else { return }
        poller = Task { [weak self] in
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { return }
                if await api.isSettled(confirming.statusURL) {
                    if Task.isCancelled { return }
                    self?.load(.silently) { try await api.sheet(at: confirming.resultURL) }
                    return
                }
            }
            self?.outcomeView?.stopProgress()
        }
    }

    private func openReceipt() {
        guard let api, let outcomeView, let receipt = sheet?.result?.receipt, !outcomeView.isOpeningReceipt else { return }
        if receiptFile != nil { return presentReceipt() }
        outcomeView.isOpeningReceipt = true
        let name = "Rais-\(sheet?.result?.outcome?.orderNumber ?? sheet?.payment?.id ?? "receipt").pdf".replacingOccurrences(of: "/", with: "-")
        Task { [weak self] in
            let file = try? await api.downloadReceipt(receipt.url, name: name)
            guard let self, !self.finished else { return }
            outcomeView.isOpeningReceipt = false
            guard let file else { return self.showNotice(self.context?.words["js.connection"]) }
            self.receiptFile = file
            self.showNotice(nil)
            self.presentReceipt()
        }
    }

    private func presentReceipt() {
        let preview = QLPreviewController()
        preview.dataSource = self
        present(preview, animated: true)
    }

    private func emailReceipt(to address: String?) {
        guard let api, let outcomeView, let context else { return }
        Task { [weak self] in
            do {
                let sent = try await api.emailReceipt(to: address)
                outcomeView.receiptEmailed(to: sent)
                self?.showNotice(nil)
            } catch let refusal as CheckoutAPI.Refusal {
                let text = context.words.describing(refusal)
                if !outcomeView.receiptEmailFailed(text) { self?.showNotice(text) }
            } catch {
                let text = context.words["js.connection"]
                if !outcomeView.receiptEmailFailed(text) { self?.showNotice(text) }
            }
        }
    }

    /// Back from the Raïs app, where the payer may have paid this very payment: read it again.
    @objc private func cameBack() {
        guard leftForApp, phase == .pay, !isBusy else { return }
        leftForApp = false
        reload(.silently)
    }

    // MARK: The web checkout, inside this screen

    private func showWeb(_ url: URL, cookies: [HTTPCookie]) {
        guard web == nil else { return }
        phase = .web
        poller?.cancel()
        spinner.stopAnimating()
        let screen = WebCheckoutViewController(url: url, configuration: configuration, cookies: cookies) { [weak self] result in
            self?.finish(with: result)
        }
        web = screen
        addChild(screen)
        screen.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(screen.view)
        NSLayoutConstraint.activate([
            screen.view.topAnchor.constraint(equalTo: view.topAnchor),
            screen.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            screen.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screen.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        screen.didMove(toParent: self)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarStyle: UIViewController? { web }

    // MARK: Leaving

    @objc private func closeTapped() {
        guard !isBusy else { return }
        finish()
    }

    func finish(with forced: RaisCheckout.Result? = nil) {
        if let web, forced == nil { return web.finish() }   // the web checkout knows how its payment ended, and reports here
        guard !finished else { return }
        finished = true
        poller?.cancel()
        let result = forced ?? makeResult()
        if let api {
            let abandon = phase == .code
            Task {
                if abandon { await api.cancelCode() }   // a code nobody will type must not hold the payment
                api.invalidate()
            }
        }
        let done = completion
        if presentingViewController != nil {
            dismiss(animated: true) { done(result) }
        } else {
            done(result)
        }
    }

    private func makeResult() -> RaisCheckout.Result {
        guard let outcome = lastOutcome else {
            return loadFailedShowing ? .failed(RaisCheckout.Failure(code: .loadFailed, message: Strings.loadFailedTitle(), paymentID: nil)) : .cancelled
        }
        switch outcome.status {
        case "paid":
            return .completed(RaisCheckout.Payment(id: outcome.paymentID, reference: outcome.reference, orderNumber: outcome.orderNumber))
        case "failed":
            return .failed(RaisCheckout.Failure(code: .declined, message: Strings.declined(), paymentID: outcome.paymentID))
        case "expired":
            return .failed(RaisCheckout.Failure(code: .expired, message: Strings.expired(), paymentID: outcome.paymentID))
        default:
            return .cancelled
        }
    }
}

extension NativeCheckoutViewController: UIScrollViewDelegate {
    /// A hairline over the bar while content is under it.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let hidden = scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - 1
        let alpha: CGFloat = hidden ? 0 : 1
        if barLine.alpha != alpha { UIView.animate(withDuration: 0.15) { self.barLine.alpha = alpha } }
    }
}

extension NativeCheckoutViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { receiptFile == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (receiptFile ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }
}
