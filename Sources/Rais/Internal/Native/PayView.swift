import UIKit

/// The payment to pay: who is paid and how much, then the ways to pay it (the payer's Raïs balance and cards when the checkout knows who they
/// are, the cards a store keeps for its customer, a card typed now) and whether a typed card is kept. One button, owned by the screen,
/// pays with whatever is chosen here.
final class PayView: UIView {
    enum Choice: Equatable {
        case balance
        case card(Sheet.Pay.Card)
        case newCard
    }

    struct Submission {
        let method: CheckoutAPI.Method
        let email: String?
    }

    private let context: SheetContext
    private let payment: Sheet.Payment
    private let pay: Sheet.Pay
    private var theme: SheetTheme { context.theme }
    private var words: Words { context.words }

    private let column = UIStackView()
    private let avatar: AvatarView
    private var detailsBox: UIView?
    private var detailsButton: SheetButton?
    private var choiceRows: [(choice: Choice, row: ChoiceRow)] = []
    private let newCardSection = UIStackView()
    private let savedCVCCell: InputCell
    private let savedCVCGroup: InputGroup
    private let brands = BrandMarks()
    private let panCell: InputCell
    private let expiryCell: InputCell
    private let cvcCell: InputCell
    private let nameCell: InputCell
    private let cardGroup: InputGroup
    private let nameGroup: InputGroup
    private var emailCell: InputCell?
    private var emailGroup: InputGroup?
    private var saveRow: ToggleRow?

    private(set) var choice: Choice = .newCard

    /// The chosen way to pay changed (the button's words follow it).
    var onChoice: (() -> Void)?
    /// The payer is about to type a card: time to get a session with the bank ready.
    var onCardEditing: (() -> Void)?
    /// A field took the focus: the screen brings it into view.
    var onFocus: ((UIView) -> Void)?
    var onSignOut: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    var onOpenApp: ((URL) -> Void)?
    /// The layout changed height (details opened, another way to pay chosen).
    var onResize: (() -> Void)?

    func show(logo: UIImage, animated: Bool = true) { avatar.show(logo, animated: animated) }

    init(context: SheetContext, sheet: Sheet, payment: Sheet.Payment, pay: Sheet.Pay, canOpenApp: Bool) {
        self.context = context
        self.payment = payment
        self.pay = pay
        let theme = context.theme
        let words = context.words
        avatar = AvatarView(theme: theme, name: sheet.merchant?.name ?? "")

        panCell = InputCell(theme: theme, caption: words["pay.card_number"], placeholder: "1234 1234 1234 1234", accessory: brands)
        expiryCell = InputCell(theme: theme, caption: words["pay.expiry"], placeholder: words["pay.expiry_hint"])
        cvcCell = InputCell(theme: theme, caption: words["pay.cvc"], placeholder: "•••")
        nameCell = InputCell(theme: theme, caption: words["pay.name"])
        cardGroup = InputGroup(theme: theme, rows: [[panCell], [expiryCell, cvcCell]])
        nameGroup = InputGroup(theme: theme, rows: [[nameCell]])
        savedCVCCell = InputCell(theme: theme, caption: words["saved.cvc"], placeholder: "•••")
        savedCVCGroup = InputGroup(theme: theme, rows: [[savedCVCCell]])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        column.axis = .vertical
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        buildSummary(sheet)
        buildChoices()
        buildCardForm()
        if let appURL = pay.appURL, canOpenApp {
            let open = SheetButton(theme: theme, kind: .secondary, title: words["wallet.open_app"], symbol: "arrow.up.forward.app")
            open.onTap { [weak self] in self?.onOpenApp?(appURL) }
            column.addArrangedSubview(open)
        }
        buildAgreements()
        select(initialChoice(), animated: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: What is being paid

    private func buildSummary(_ sheet: Sheet) {
        let name = UILabel()
        name.text = sheet.merchant?.name
        name.font = theme.font(17, .semibold, style: .headline)
        name.textColor = theme.text
        name.textAlignment = .center
        name.numberOfLines = 2
        name.adjustsFontForContentSizeCategory = true
        name.accessibilityLabel = words["pay.pay_to"]

        let amount = AmountLabel(context: context, number: payment.amountNumber, currency: payment.currency, size: 44, spoken: payment.amountText)

        let summary = UIStackView(arrangedSubviews: [avatar, name])
        summary.axis = .vertical
        summary.alignment = .center
        summary.spacing = 10
        if let website = sheet.merchant?.website, !website.isEmpty {
            let host = UILabel()
            host.text = website
            host.font = theme.font(13, .regular, style: .footnote)
            host.textColor = theme.secondary
            host.textAlignment = .center
            host.adjustsFontForContentSizeCategory = true
            summary.addArrangedSubview(host)
            summary.setCustomSpacing(2, after: name)
        }
        summary.addArrangedSubview(amount)
        summary.setCustomSpacing(14, after: summary.arrangedSubviews[summary.arrangedSubviews.count - 2])
        if let description = payment.description, !description.isEmpty {
            let text = UILabel()
            text.text = description
            text.font = theme.font(15, .regular, style: .subheadline)
            text.textColor = theme.secondary
            text.textAlignment = .center
            text.numberOfLines = 3
            text.adjustsFontForContentSizeCategory = true
            summary.addArrangedSubview(text)
            summary.setCustomSpacing(4, after: amount)
        }
        column.addArrangedSubview(summary)

        guard !payment.lines.isEmpty || !payment.details.isEmpty else {
            column.setCustomSpacing(28, after: summary)
            return
        }
        let toggle = SheetButton(theme: theme, kind: .plain, title: words["pay.show_details"], symbol: "chevron.down")
        toggle.accessibilityIdentifier = "rais.details"
        toggle.onTap { [weak self] in self?.toggleDetails() }
        let centered = UIStackView(arrangedSubviews: [toggle])
        centered.axis = .vertical
        centered.alignment = .center
        column.addArrangedSubview(centered)
        column.setCustomSpacing(0, after: summary)
        detailsButton = toggle

        let box = GroupBox(theme: theme)
        for line in payment.lines {
            box.add(lineRow(title: line.name, detail: [line.description, line.quantity].compactMap { $0 }.joined(separator: "\n"), value: line.totalText))
        }
        if let adjustment = payment.adjustmentText { box.add(lineRow(title: words["receipt.adjustments"], detail: "", value: adjustment)) }
        if !payment.lines.isEmpty { box.add(lineRow(title: words["pay.total"], detail: "", value: payment.amountText, strong: true)) }
        let details = UIStackView(arrangedSubviews: payment.lines.isEmpty ? [] : [box])
        details.axis = .vertical
        details.spacing = 12
        if !payment.details.isEmpty { details.addArrangedSubview(RowsCard(context: context, rows: payment.details)) }
        details.isHidden = true
        details.alpha = 0
        column.addArrangedSubview(details)
        column.setCustomSpacing(4, after: centered)
        column.setCustomSpacing(24, after: details)
        detailsBox = details
    }

    private func lineRow(title: String, detail: String, value: String, strong: Bool = false) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = theme.font(15, strong ? .semibold : .medium, style: .subheadline)
        name.textColor = theme.text
        name.numberOfLines = 0
        let sub = UILabel()
        sub.text = detail
        sub.font = theme.font(13, .regular, style: .footnote, digits: true)
        sub.textColor = theme.secondary
        sub.numberOfLines = 0
        sub.isHidden = detail.isEmpty
        let left = UIStackView(arrangedSubviews: [name, sub])
        left.axis = .vertical
        left.spacing = 2
        let total = UILabel()
        total.text = value
        total.font = theme.font(15, strong ? .semibold : .medium, style: .subheadline, digits: true)
        total.textColor = theme.text
        total.textAlignment = context.trailingAlignment
        total.setContentHuggingPriority(.required, for: .horizontal)
        total.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [left, total])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 16
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        for label in [name, sub, total] { label.adjustsFontForContentSizeCategory = true }
        return row
    }

    private func toggleDetails() {
        guard let detailsBox, let detailsButton else { return }
        let show = detailsBox.isHidden
        detailsButton.title = words[show ? "pay.hide_details" : "pay.show_details"]
        detailsButton.symbol = show ? "chevron.up" : "chevron.down"
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            detailsBox.isHidden = !show
            detailsBox.alpha = show ? 1 : 0
            self.onResize?()
        }
    }

    // MARK: The ways to pay

    private func buildChoices() {
        var choices: [Choice] = []
        if pay.balance != nil { choices.append(.balance) }
        choices += pay.cards.map(Choice.card)
        guard !choices.isEmpty else {
            column.addArrangedSubview(heading(words["pay.title"]))
            return
        }
        choices.append(.newCard)

        if pay.payer != nil {
            let who = heading(words["wallet.paying_as"])
            let leave = SheetButton(theme: theme, kind: .plain, title: words["wallet.not_you"])
            leave.accessibilityIdentifier = "rais.signout"
            leave.onTap { [weak self] in self?.onSignOut?() }
            leave.setContentHuggingPriority(.required, for: .horizontal)
            who.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [who, leave])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            column.addArrangedSubview(row)
            column.setCustomSpacing(4, after: row)
        } else {
            column.addArrangedSubview(heading(words["saved.title"]))
        }

        let box = GroupBox(theme: theme)
        for choice in choices {
            let row: ChoiceRow
            switch choice {
            case .balance:
                let balance = pay.balance
                let icon = UIImageView(image: SheetAssets.image("rais-mark"))
                icon.contentMode = .scaleAspectFit
                icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
                let enough = balance?.enough ?? false
                row = ChoiceRow(theme: theme, title: words["sheet.balance"], detail: enough ? balance?.text : (balance?.shortText ?? balance?.text), mark: icon)
                row.isEnabled = enough
                row.accessibilityIdentifier = "rais.choice.balance"
            case .card(let card):
                row = ChoiceRow(theme: theme, title: "•••• \(card.last4)", detail: "\(words["pay.expiry"]) \(card.expiry)", latinTitle: true,
                                mark: BrandMarks.single(card.brand, size: 30) ?? Self.cardGlyph(theme))
                row.accessibilityIdentifier = "rais.choice.card"
            case .newCard:
                row = ChoiceRow(theme: theme, title: words[pay.payer != nil ? "wallet.other_card" : "saved.other"], detail: nil, mark: Self.cardGlyph(theme, symbol: "plus"))
                row.accessibilityIdentifier = "rais.choice.new"
            }
            row.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.select(choice, animated: true)
            }, for: .touchUpInside)
            choiceRows.append((choice, row))
            box.add(row)
        }
        column.addArrangedSubview(box)

        if let balance = pay.balance, !balance.enough, let topup = balance.topupURL {
            let link = SheetButton(theme: theme, kind: .plain, title: words["wallet.top_up"], symbol: "plus.circle")
            link.onTap { [weak self] in self?.onOpen?(topup) }
            let leading = UIStackView(arrangedSubviews: [link, UIView()])
            leading.axis = .horizontal
            column.addArrangedSubview(leading)
            column.setCustomSpacing(0, after: box)
        }

        savedCVCCell.field.keyboardType = .numberPad
        savedCVCCell.field.isSecureTextEntry = true
        savedCVCCell.field.accessibilityIdentifier = "rais.saved.cvc"
        savedCVCCell.formatter = { String(CardRules.digits($0).prefix(CardRules.cvcLength)) }
        savedCVCCell.onChange = { [weak self] in self?.savedCVCGroup.setError(nil) }
        savedCVCGroup.onFocus = { [weak self] _ in self.map { $0.onFocus?($0.savedCVCGroup) } }
        savedCVCGroup.isHidden = true
        column.addArrangedSubview(savedCVCGroup)
    }

    private static func cardGlyph(_ theme: SheetTheme, symbol: String = "creditcard") -> UIView {
        let icon = UIImageView(image: Glyph.image(symbol, size: 15, weight: .medium))
        icon.tintColor = theme.secondary
        icon.contentMode = .center
        icon.backgroundColor = theme.background
        icon.layer.cornerRadius = 7
        icon.layer.cornerCurve = .continuous
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return icon
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = theme.font(15, .semibold, style: .subheadline)
        label.textColor = theme.text
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityTraits = .header
        return label
    }

    private func initialChoice() -> Choice {
        if let chosen = pay.chosen, let card = pay.cards.first(where: { $0.id == chosen }) { return .card(card) }
        if pay.balance?.enough == true { return .balance }
        if let first = pay.cards.first { return .card(first) }
        return .newCard
    }

    private func select(_ new: Choice, animated: Bool) {
        choice = new
        for (candidate, row) in choiceRows { row.isSelected = candidate == new }
        var needsCVC = false
        if case .card(let card) = new { needsCVC = card.needsCVC }
        if case .card(let card) = new { savedCVCCell.field.accessibilityLabel = words("wallet.card_cvc", ["last4": card.last4]) }
        let typing = new == .newCard
        let changes = {
            self.savedCVCGroup.isHidden = !needsCVC
            self.savedCVCGroup.alpha = needsCVC ? 1 : 0
            self.newCardSection.isHidden = !typing
            self.newCardSection.alpha = typing ? 1 : 0
            self.saveRow?.isHidden = !typing
            self.saveRow?.alpha = typing ? 1 : 0
            self.onResize?()
        }
        if animated {
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
        if !typing { endEditing(true) }
        if needsCVC, animated { savedCVCCell.focus() }
        onChoice?()
    }

    // MARK: A card typed now

    private func buildCardForm() {
        panCell.field.keyboardType = .numberPad
        panCell.field.textContentType = .creditCardNumber
        panCell.field.accessibilityIdentifier = "rais.card.number"
        panCell.formatter = CardRules.formatPAN
        expiryCell.field.keyboardType = .numberPad
        expiryCell.field.accessibilityIdentifier = "rais.card.expiry"
        expiryCell.formatter = CardRules.formatExpiry
        cvcCell.field.keyboardType = .numberPad
        cvcCell.field.isSecureTextEntry = true
        cvcCell.field.accessibilityIdentifier = "rais.card.cvc"
        cvcCell.formatter = { String(CardRules.digits($0).prefix(CardRules.cvcLength)) }
        nameCell.field.keyboardType = .asciiCapable
        nameCell.field.autocapitalizationType = .allCharacters
        nameCell.field.returnKeyType = .done
        nameCell.field.accessibilityIdentifier = "rais.card.name"
        nameCell.maxLength = 26
        if #available(iOS 17.0, *) {
            expiryCell.field.textContentType = .creditCardExpiration
            cvcCell.field.textContentType = .creditCardSecurityCode
            nameCell.field.textContentType = .creditCardName
        } else {
            nameCell.field.textContentType = .name
        }

        panCell.onChange = { [weak self] in
            guard let self else { return }
            let number = CardRules.digits(self.panCell.text)
            self.brands.show(CardRules.brand(of: number))
            self.cardGroup.setError(nil)
            if number.count == CardRules.panLength, self.panCell.field.isFirstResponder { self.expiryCell.focus() }
        }
        expiryCell.onChange = { [weak self] in
            guard let self else { return }
            self.cardGroup.setError(nil)
            if CardRules.digits(self.expiryCell.text).count == 4, self.expiryCell.field.isFirstResponder { self.cvcCell.focus() }
        }
        cvcCell.onChange = { [weak self] in
            guard let self else { return }
            self.cardGroup.setError(nil)
            if self.cvcCell.text.count == CardRules.cvcLength, self.cvcCell.field.isFirstResponder, self.nameCell.text.isEmpty { self.nameCell.focus() }
        }
        nameCell.onChange = { [weak self] in self?.nameGroup.setError(nil) }
        cardGroup.onFocus = { [weak self] _ in
            guard let self else { return }
            self.onCardEditing?()
            self.onFocus?(self.cardGroup)
        }
        nameGroup.onFocus = { [weak self] _ in
            guard let self else { return }
            self.onCardEditing?()
            self.onFocus?(self.nameGroup)
        }

        newCardSection.axis = .vertical
        newCardSection.spacing = 12
        newCardSection.addArrangedSubview(cardGroup)
        newCardSection.addArrangedSubview(nameGroup)
        column.addArrangedSubview(newCardSection)
    }

    // MARK: The receipt address, and whether the card is kept

    private func buildAgreements() {
        if pay.receiptEmail {
            let cell = InputCell(theme: theme, caption: words["pay.email"], placeholder: "name@example.com")
            cell.field.keyboardType = .emailAddress
            cell.field.textContentType = .emailAddress
            cell.field.returnKeyType = .done
            cell.field.accessibilityIdentifier = "rais.email"
            cell.maxLength = 254
            let group = InputGroup(theme: theme, rows: [[cell]], note: words["pay.email_note"])
            cell.onChange = { [weak group] in group?.setError(nil) }
            group.onFocus = { [weak self, weak group] _ in if let group { self?.onFocus?(group) } }
            column.addArrangedSubview(group)
            emailCell = cell
            emailGroup = group
        }

        if let save = pay.save {
            let row = ToggleRow(theme: theme, text: save.label, isOn: save.checked)
            row.accessibilityIdentifier = "rais.save"
            column.addArrangedSubview(row)
            saveRow = row
        }
    }

    // MARK: Reading what was typed

    /// What to pay with, once everything that is needed is there and right. Otherwise says what is wrong, at the fields, puts the payer in
    /// the first of them, and returns `nil`.
    func collect() -> Submission? {
        var firstWrong: InputCell?
        func wrong(_ cell: InputCell) { if firstWrong == nil { firstWrong = cell } }
        var method: CheckoutAPI.Method?

        switch choice {
        case .balance:
            method = .balance
        case .card(let card):
            if card.needsCVC {
                if let problem = CardRules.checkCVC(savedCVCCell.text) {
                    savedCVCGroup.setError(words[problem], on: [savedCVCCell])
                    wrong(savedCVCCell)
                } else {
                    method = .card(card, cvc: savedCVCCell.text)
                }
            } else {
                method = .card(card, cvc: nil)
            }
        case .newCard:
            let problems: [(InputCell, String?)] = [
                (panCell, CardRules.checkPAN(panCell.text, sandbox: context.sandbox)),
                (expiryCell, CardRules.checkExpiry(expiryCell.text, sandbox: context.sandbox)),
                (cvcCell, CardRules.checkCVC(cvcCell.text)),
            ]
            let bad = problems.filter { $0.1 != nil }
            cardGroup.setError(bad.first.flatMap { $0.1 }.map { words[$0] }, on: bad.map { $0.0 })
            if let first = bad.first { wrong(first.0) }
            let nameProblem = CardRules.checkName(nameCell.text)
            nameGroup.setError(nameProblem.map { words[$0] }, on: nameProblem == nil ? [] : [nameCell])
            if nameProblem != nil { wrong(nameCell) }
            if bad.isEmpty, nameProblem == nil {
                let expiry = CardRules.digits(expiryCell.text)
                let card = TypedCard(pan: CardRules.digits(panCell.text), cvc: cvcCell.text, expiryMonth: String(expiry.prefix(2)),
                                     expiryYear: "20" + expiry.suffix(2), holder: CardRules.cleanName(nameCell.text).uppercased())
                method = .newCard(card, save: saveRow?.isOn ?? false)
            }
        }

        var email: String?
        if let emailCell, let emailGroup {
            let typed = emailCell.text.trimmingCharacters(in: .whitespaces)
            if let problem = CardRules.checkEmail(typed) {
                emailGroup.setError(words[problem], on: [emailCell])
                wrong(emailCell)
            } else {
                email = typed.isEmpty ? nil : typed
            }
        }

        if let firstWrong {
            firstWrong.focus()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return nil
        }
        guard let method else { return nil }
        return Submission(method: method, email: email)
    }

    /// The server refused the receipt address: said at its field, like the screen's own checks.
    func showEmailProblem(_ text: String) -> Bool {
        guard let emailCell, let emailGroup else { return false }
        emailGroup.setError(text, on: [emailCell])
        emailCell.focus()
        return true
    }

    /// The server refused the security code of a saved card.
    func showSavedCVCProblem(_ text: String) -> Bool {
        guard case .card(let card) = choice, card.needsCVC else { return false }
        savedCVCGroup.setError(text, on: [savedCVCCell])
        savedCVCCell.focus()
        return true
    }

    /// A card whose code the server turned out to need.
    func askForSavedCVC() -> Bool {
        guard case .card = choice else { return false }
        savedCVCGroup.isHidden = false
        savedCVCGroup.alpha = 1
        savedCVCGroup.setError(words["js.code.cvc_required"], on: [savedCVCCell])
        savedCVCCell.focus()
        onResize?()
        return true
    }

    var buttonTitle: String { words[choice == .balance ? "wallet.pay_balance" : "pay.cta"] }

    /// A payment is on its way: nothing can be changed until it answers.
    var isBusy = false {
        didSet {
            isUserInteractionEnabled = !isBusy
            if isBusy { endEditing(true) }
        }
    }
}

/// An amount as its own picture: the figures large, the currency smaller beside them, on one line whatever the language.
final class AmountLabel: UILabel {
    init(context: SheetContext, number: String, currency: String, size: CGFloat, spoken: String) {
        super.init(frame: .zero)
        let theme = context.theme
        let text = NSMutableAttributedString(string: number, attributes: [
            .font: theme.font(size, .bold, style: .largeTitle, digits: true), .foregroundColor: theme.text, .kern: -0.6,
        ])
        if !currency.isEmpty {
            text.append(NSAttributedString(string: " \(currency)", attributes: [
                .font: theme.font(size * 0.5, .semibold, style: .title3), .foregroundColor: theme.secondary,
            ]))
        }
        attributedText = text
        textAlignment = .center
        adjustsFontSizeToFitWidth = true
        minimumScaleFactor = 0.5
        numberOfLines = 1
        accessibilityLabel = spoken
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
