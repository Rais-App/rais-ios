import UIKit

/// The bank's step: the code it sent to the cardholder.
final class CodeView: UIView {
    let code: CodeField
    private let problem = UILabel()
    private let context: SheetContext

    init(context: SheetContext, maskedCard: String?, length: Int) {
        self.context = context
        let theme = context.theme
        let words = context.words
        code = CodeField(theme: theme, length: length, label: words["otp.label"])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        code.accessibilityIdentifier = "rais.code"

        let title = UILabel()
        title.text = words["otp.title"]
        title.font = theme.font(22, .bold, style: .title2)
        title.textColor = theme.text
        title.accessibilityTraits = .header
        let lead = UILabel()
        lead.text = words["otp.subtitle"]
        lead.font = theme.font(15, .regular, style: .subheadline)
        lead.textColor = theme.secondary

        let head = UIStackView(arrangedSubviews: [IconDisc(theme: theme, symbol: "lock.shield", color: theme.text), title, lead])
        head.axis = .vertical
        head.alignment = .center
        head.spacing = 8
        head.setCustomSpacing(16, after: head.arrangedSubviews[0])
        let masked = CardRules.formatMasked(maskedCard)
        if !masked.isEmpty {
            let card = UILabel()
            card.text = masked
            card.font = theme.mono(15, .medium)
            card.textColor = theme.text
            card.semanticContentAttribute = .forceLeftToRight
            head.addArrangedSubview(card)
            head.setCustomSpacing(12, after: lead)
        }

        problem.font = theme.font(13, .regular, style: .footnote)
        problem.textColor = theme.danger
        problem.isHidden = true

        let caution = UIImageView(image: Glyph.image("exclamationmark.triangle.fill", size: 12))
        caution.tintColor = theme.warning
        caution.setContentHuggingPriority(.required, for: .horizontal)
        let warning = UILabel()
        warning.text = words["otp.warning"]
        warning.font = theme.font(13, .regular, style: .footnote)
        warning.textColor = theme.secondary
        let warn = UIStackView(arrangedSubviews: [caution, warning])
        warn.axis = .horizontal
        warn.alignment = .firstBaseline
        warn.spacing = 6
        let warnCentered = UIStackView(arrangedSubviews: [warn])
        warnCentered.axis = .vertical
        warnCentered.alignment = .center

        for label in [title, lead, problem, warning] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        let column = UIStackView(arrangedSubviews: [head, code, problem, warnCentered])
        column.axis = .vertical
        column.spacing = 12
        column.setCustomSpacing(28, after: head)
        column.setCustomSpacing(20, after: problem)
        column.setCustomSpacing(20, after: code)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Says what is wrong with the code under its cells; `nil` clears it.
    func setProblem(_ text: String?) {
        problem.text = text
        problem.isHidden = text == nil
        code.hasError = text != nil
        if let text {
            code.shake()
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}

/// What became of a payment: paid, refused, expired, cancelled, or still being confirmed with the bank. The server words all of it; this
/// draws it, and offers what can be done next (the receipt, another try).
final class OutcomeView: UIView {
    private let context: SheetContext
    private var theme: SheetTheme { context.theme }
    private var words: Words { context.words }
    private let column = UIStackView()
    private var emailButton: SheetButton?
    private var emailCell: InputCell?
    private var emailGroup: InputGroup?
    private var sendButton: SheetButton?
    private var emailForm: UIStackView?
    private var receiptButton: SheetButton?
    private let progress = UIActivityIndicatorView(style: .medium)
    private var progressRow: UIStackView?

    var onViewReceipt: (() -> Void)?
    /// E-mail the receipt, to the address typed here when the payment has none.
    var onEmailReceipt: ((String?) -> Void)?
    var onContact: ((String) -> Void)?
    var onFocus: ((UIView) -> Void)?
    var onResize: (() -> Void)?

    init(context: SheetContext, sheet: Sheet, result: Sheet.Outcome) {
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let theme = context.theme
        let words = context.words

        let color: UIColor
        switch result.tone {
        case .ok: color = theme.success
        case .bad: color = theme.danger
        case .neutral: color = theme.secondary
        }
        let title = UILabel()
        title.text = result.title
        title.font = theme.font(22, .bold, style: .title2)
        title.textColor = theme.text
        title.accessibilityTraits = .header
        title.accessibilityIdentifier = "rais.outcome.title"
        let head = UIStackView(arrangedSubviews: [IconDisc(theme: theme, symbol: Glyph.symbol(forOutcome: result.icon), color: color), title])
        head.axis = .vertical
        head.alignment = .center
        head.spacing = 16
        if let lead = result.lead, !lead.isEmpty {
            let label = UILabel()
            label.text = lead
            label.font = theme.font(15, .regular, style: .subheadline)
            label.textColor = theme.secondary
            centered(label)
            head.addArrangedSubview(label)
            head.setCustomSpacing(6, after: title)
        }
        centered(title)

        if result.confirming != nil {
            let label = UILabel()
            label.text = words["confirming.checking"]
            label.font = theme.font(14, .medium, style: .subheadline)
            label.textColor = theme.secondary
            label.adjustsFontForContentSizeCategory = true
            progress.color = theme.secondary
            progress.startAnimating()
            let row = UIStackView(arrangedSubviews: [progress, label])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center
            head.addArrangedSubview(row)
            progressRow = row
        }

        if let payment = sheet.payment {
            let amount = AmountLabel(context: context, number: payment.amountNumber, currency: payment.currency, size: 34, spoken: payment.amountText)
            head.addArrangedSubview(amount)
            head.setCustomSpacing(18, after: head.arrangedSubviews[head.arrangedSubviews.count - 2])
            if let name = sheet.merchant?.name {
                let merchant = UILabel()
                merchant.text = name
                merchant.font = theme.font(15, .medium, style: .subheadline)
                merchant.textColor = theme.secondary
                centered(merchant)
                head.addArrangedSubview(merchant)
                head.setCustomSpacing(2, after: amount)
            }
        }

        column.axis = .vertical
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        column.addArrangedSubview(head)
        column.setCustomSpacing(24, after: head)

        if let note = result.note, !note.isEmpty {
            let isReceiptNote = result.receipt != nil
            column.addArrangedSubview(NoticeView(theme: theme, tone: .neutral, text: note, symbol: isReceiptNote ? "envelope.fill" : nil))
        }
        if !result.rows.isEmpty { column.addArrangedSubview(RowsCard(context: context, rows: result.rows)) }

        if let receipt = result.receipt {
            let view = SheetButton(theme: theme, kind: .secondary, title: words["sheet.view_receipt"], symbol: "doc.text")
            view.accessibilityIdentifier = "rais.receipt"
            view.onTap { [weak self] in self?.onViewReceipt?() }
            receiptButton = view
            var buttons: [UIView] = [view]
            if let mail = receipt.mail {
                let send = SheetButton(theme: theme, kind: .secondary, title: words[mail.sent ? "result.receipt_emailed" : "result.email_receipt"],
                                       symbol: mail.sent ? "checkmark" : "envelope")
                send.accessibilityIdentifier = "rais.receipt.email"
                send.isEnabled = !mail.sent
                send.onTap { [weak self] in self?.emailTapped(known: mail.known != nil) }
                emailButton = send
                buttons.append(send)
            }
            let row = UIStackView(arrangedSubviews: buttons)
            row.axis = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            column.addArrangedSubview(row)
            column.setCustomSpacing(16, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])

            if let mail = receipt.mail, !mail.sent, mail.known == nil {
                let cell = InputCell(theme: theme, caption: words["result.email_label"], placeholder: "name@example.com")
                cell.field.keyboardType = .emailAddress
                cell.field.textContentType = .emailAddress
                cell.field.returnKeyType = .send
                cell.field.accessibilityIdentifier = "rais.receipt.address"
                cell.maxLength = 254
                let group = InputGroup(theme: theme, rows: [[cell]], note: words["result.email_hint"])
                let send = SheetButton(theme: theme, kind: .secondary, title: words["result.email_send"], symbol: "paperplane")
                send.onTap { [weak self] in self?.sendTyped() }
                cell.onChange = { [weak group] in group?.setError(nil) }
                cell.onReturn = { [weak self] in self?.sendTyped() }
                group.onFocus = { [weak self, weak group] _ in if let group { self?.onFocus?(group) } }
                let form = UIStackView(arrangedSubviews: [group, send])
                form.axis = .vertical
                form.spacing = 10
                form.isHidden = true
                form.alpha = 0
                column.addArrangedSubview(form)
                emailCell = cell
                emailGroup = group
                sendButton = send
                emailForm = form
            }
        }

        if let address = result.contactEmail, !address.isEmpty {
            let contact = SheetButton(theme: theme, kind: .secondary, title: words["expired.contact"], symbol: "envelope")
            contact.onTap { [weak self] in self?.onContact?(address) }
            column.addArrangedSubview(contact)
        }

        if let support = result.support, !support.isEmpty {
            let label = UILabel()
            label.text = support
            label.font = theme.font(12, .regular, style: .caption1)
            label.textColor = theme.secondary
            centered(label)
            column.addArrangedSubview(label)
            column.setCustomSpacing(20, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func centered(_ label: UILabel) {
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
    }

    /// The bank still names no outcome and the screen stopped asking by itself: the payer can ask again.
    func stopProgress() {
        progressRow?.isHidden = true
    }

    // MARK: The receipt

    var isOpeningReceipt = false {
        didSet { receiptButton?.isLoading = isOpeningReceipt }
    }

    private func emailTapped(known: Bool) {
        guard let emailForm, !known else {
            emailButton?.isLoading = true
            onEmailReceipt?(nil)
            return
        }
        let show = emailForm.isHidden
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            emailForm.isHidden = !show
            emailForm.alpha = show ? 1 : 0
            self.onResize?()
        }
        if show { emailCell?.focus() } else { endEditing(true) }
    }

    private func sendTyped() {
        guard let emailCell, let emailGroup else { return }
        let address = emailCell.text.trimmingCharacters(in: .whitespaces)
        if address.isEmpty {
            emailGroup.setError(words["js.receipt_email_required"], on: [emailCell])
            return
        }
        if CardRules.checkEmail(address) != nil {
            emailGroup.setError(words["js.receipt_email_invalid"], on: [emailCell])
            return
        }
        sendButton?.isLoading = true
        emailCell.field.resignFirstResponder()
        onEmailReceipt?(address)
    }

    /// The receipt went (or had already gone) to `address`, masked by the server.
    func receiptEmailed(to address: String) {
        emailButton?.isLoading = false
        sendButton?.isLoading = false
        emailButton?.title = words["result.receipt_emailed"]
        emailButton?.symbol = "checkmark"
        emailButton?.isEnabled = false
        emailButton?.accessibilityValue = address
        if let emailForm, !emailForm.isHidden {
            UIView.animate(withDuration: 0.25) {
                emailForm.isHidden = true
                emailForm.alpha = 0
                self.onResize?()
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: words("js.receipt_sent", ["email": address]))
    }

    /// The receipt could not be e-mailed. Returns whether the problem was shown at the address field (else the screen says it).
    func receiptEmailFailed(_ text: String) -> Bool {
        emailButton?.isLoading = false
        sendButton?.isLoading = false
        guard let emailCell, let emailGroup, let emailForm, !emailForm.isHidden else { return false }
        emailGroup.setError(text, on: [emailCell])
        return true
    }
}
