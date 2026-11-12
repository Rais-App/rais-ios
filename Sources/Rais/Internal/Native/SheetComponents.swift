import UIKit

/// What every part of the native checkout is built with: the look, the server's words, and the reading direction of those words (which
/// may differ from the app's own).
struct SheetContext {
    let theme: SheetTheme
    let words: Words
    let rtl: Bool
    let sandbox: Bool

    /// The side text ends on, for a value at the far edge of its row.
    var trailingAlignment: NSTextAlignment { rtl ? .left : .right }
}

// MARK: - Buttons

/// The checkout's button: a filled one for the action of the screen, a quiet one for what is beside it, a plain one for a way out.
final class SheetButton: UIControl {
    enum Kind { case primary, secondary, plain }

    private let theme: SheetTheme
    private let kind: Kind
    private let label = UILabel()
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let row = UIStackView()

    var title: String {
        didSet { label.text = title; accessibilityLabel = title }
    }

    var symbol: String? {
        didSet { applySymbol() }
    }

    /// A request is on its way: the title gives way to a spinner and the button takes no tap.
    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            row.alpha = isLoading ? 0 : 1
            isLoading ? spinner.startAnimating() : spinner.stopAnimating()
            isUserInteractionEnabled = !isLoading
            if isLoading { accessibilityTraits.insert(.updatesFrequently) } else { accessibilityTraits.remove(.updatesFrequently) }
        }
    }

    init(theme: SheetTheme, kind: Kind, title: String, symbol: String? = nil) {
        self.theme = theme
        self.kind = kind
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title

        label.text = title
        label.font = theme.font(kind == .plain ? 15 : 17, .semibold, style: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.textAlignment = .center
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        addSubview(row)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        layer.cornerRadius = theme.radius
        layer.cornerCurve = .continuous
        // as tall as its kind asks, taller only when large text needs it; never stretched by the room around it
        let snug = heightAnchor.constraint(equalToConstant: kind == .plain ? 44 : 54)
        snug.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: kind == .plain ? 44 : 54),
            snug,
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: kind == .plain ? 4 : 16),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if kind == .plain {
            // a plain button is as wide as its words (a link in a row); a row that gives it more room keeps the words in the middle
            let hug = widthAnchor.constraint(equalTo: row.widthAnchor, constant: 8)
            hug.priority = .defaultLow
            hug.isActive = true
        }
        applySymbol()
        applyColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applySymbol() {
        icon.image = symbol.flatMap { Glyph.image($0, size: kind == .plain ? 13 : 15) }
        icon.isHidden = icon.image == nil
    }

    private func applyColors() {
        let ink: UIColor
        switch kind {
        case .primary:
            backgroundColor = theme.primary
            ink = theme.onPrimary
        case .secondary:
            backgroundColor = theme.surface
            ink = theme.text
        case .plain:
            backgroundColor = .clear
            ink = theme.secondary
        }
        label.textColor = ink
        icon.tintColor = ink
        spinner.color = ink
        alpha = isEnabled ? (isHighlighted ? 0.72 : 1) : 0.4
    }

    override var isHighlighted: Bool { didSet { applyColors() } }
    override var isEnabled: Bool { didSet { applyColors() } }

    func onTap(_ action: @escaping () -> Void) {
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
}

// MARK: - Fields

/// One field: a small caption that never moves and the value under it. Several of them make an `InputGroup`.
final class InputCell: ThemedView, UITextFieldDelegate {
    let field = UITextField()
    private let caption = UILabel()
    private let column = UIStackView()
    private let row = UIStackView()

    /// Rewrites what is typed (groups of four, "MM / YY", digits only); the caret stays where the payer is typing.
    var formatter: ((String) -> String)?
    var maxLength: Int?
    var onChange: (() -> Void)?
    var onReturn: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    var text: String {
        get { field.text ?? "" }
        set { field.text = formatter?(newValue) ?? newValue }
    }

    var hasError = false {
        didSet { caption.textColor = hasError ? theme.danger : theme.secondary }
    }

    /// - Parameter latin: the value is digits or Latin letters (a card number, an e-mail address): it reads left to right in every language.
    init(theme: SheetTheme, caption title: String, placeholder: String? = nil, latin: Bool = true, accessory: UIView? = nil) {
        super.init(theme: theme)
        caption.text = title
        caption.font = theme.font(12, .medium, style: .caption1)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = theme.secondary
        caption.isAccessibilityElement = false

        field.delegate = self
        field.font = theme.font(17, .regular, digits: true)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = theme.text
        field.tintColor = theme.primary
        field.accessibilityLabel = title
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        if let placeholder {
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: theme.tertiary])
        }
        if latin {
            field.semanticContentAttribute = .forceLeftToRight
            field.textAlignment = .left
        }
        field.addTarget(self, action: #selector(edited), for: .editingChanged)

        column.axis = .vertical
        column.spacing = 3
        column.addArrangedSubview(caption)
        column.addArrangedSubview(field)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(column)
        if let accessory {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(accessory)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus)))
    }

    @objc func focus() { field.becomeFirstResponder() }
    @objc private func edited() { onChange?() }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = (textField.text ?? "") as NSString
        guard range.location + range.length <= current.length else { return false }
        guard let formatter else {
            guard let maxLength else { return true }
            return current.length - range.length + (string as NSString).length <= maxLength
        }
        var proposed = current.replacingCharacters(in: range, with: string) as NSString
        var caret = range.location + (string as NSString).length
        if string.isEmpty, range.length == 1, CardRules.digits(current.substring(with: range)).isEmpty {
            // Backspace over a separator takes the digit before it too, or the separator would only come back.
            var index = range.location - 1
            while index >= 0, CardRules.digits(current.substring(with: NSRange(location: index, length: 1))).isEmpty { index -= 1 }
            if index >= 0 {
                proposed = current.replacingCharacters(in: NSRange(location: index, length: range.location + 1 - index), with: "") as NSString
                caret = index
            }
        }
        let digitsBefore = CardRules.digits(proposed.substring(to: min(caret, proposed.length))).count
        let formatted = formatter(proposed as String)
        textField.text = formatted

        let units = Array(formatted.utf16)
        func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
        var position = 0
        var seen = 0
        while position < units.count, seen < digitsBefore {
            if isDigit(units[position]) { seen += 1 }
            position += 1
        }
        if !string.isEmpty { while position < units.count, !isDigit(units[position]) { position += 1 } }
        if let place = textField.position(from: textField.beginningOfDocument, offset: position) {
            textField.selectedTextRange = textField.textRange(from: place, to: place)
        }
        onChange?()
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let onReturn { onReturn() } else { textField.resignFirstResponder() }
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { onFocus?(true) }
    func textFieldDidEndEditing(_ textField: UITextField) { onFocus?(false) }
}

/// Fields that belong together, in one bordered box: rows of one or more cells, a hairline between them, and under the box the first thing
/// that is wrong with what was typed.
final class InputGroup: ThemedView {
    private let box = UIView()
    private let message = UILabel()
    private let note = UILabel()
    private var separators: [UIView] = []
    private(set) var cells: [InputCell] = []
    private var focusCount = 0

    init(theme: SheetTheme, rows: [[InputCell]], note text: String? = nil) {
        super.init(theme: theme)
        box.backgroundColor = theme.surface
        box.layer.cornerRadius = theme.radius
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 1
        box.clipsToBounds = true

        let column = UIStackView()
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        for (index, cellsOfRow) in rows.enumerated() {
            if index > 0 { column.addArrangedSubview(hairline(horizontal: true)) }
            let row = UIStackView()
            row.axis = .horizontal
            row.semanticContentAttribute = .unspecified
            for (position, cell) in cellsOfRow.enumerated() {
                if position > 0 { row.addArrangedSubview(hairline(horizontal: false)) }
                row.addArrangedSubview(cell)
                if position > 0 { cell.widthAnchor.constraint(equalTo: cellsOfRow[0].widthAnchor).isActive = true }
                cells.append(cell)
                cell.onFocus = { [weak self, weak cell] on in
                    guard let self else { return }
                    self.focusCount += on ? 1 : -1
                    self.refresh()
                    if on, let cell { self.onFocus?(cell) }
                }
            }
            column.addArrangedSubview(row)
        }
        box.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: box.topAnchor),
            column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])

        message.font = theme.font(13, .regular, style: .footnote)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = theme.danger
        message.numberOfLines = 0
        message.isHidden = true
        note.font = theme.font(13, .regular, style: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = theme.secondary
        note.numberOfLines = 0
        note.text = text
        note.isHidden = text == nil

        let outer = UIStackView(arrangedSubviews: [box, message, note])
        outer.axis = .vertical
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// A field of the group took the focus.
    var onFocus: ((InputCell) -> Void)?

    private func hairline(horizontal: Bool) -> UIView {
        let line = UIView()
        line.backgroundColor = theme.line
        (horizontal ? line.heightAnchor : line.widthAnchor).constraint(equalToConstant: 1).isActive = true
        separators.append(line)
        return line
    }

    /// Says what is wrong under the box and marks the fields it is about; `nil` clears it.
    func setError(_ text: String?, on wrong: [InputCell] = []) {
        for cell in cells { cell.hasError = text != nil && wrong.contains { $0 === cell } }
        message.text = text
        message.isHidden = text == nil
        if text != nil { UIAccessibility.post(notification: .announcement, argument: text) }
        refresh()
    }

    var hasError: Bool { !message.isHidden }

    override func refresh() {
        let color = hasError ? theme.danger : (focusCount > 0 ? theme.primary : theme.border)
        box.layer.borderColor = cg(color)
        box.layer.borderWidth = hasError || focusCount > 0 ? 1.5 : 1
    }
}

// MARK: - A checkbox with its sentence

/// A checkbox and what it means. Part of the sentence may be a link (the terms): the link opens, the rest ticks.
final class CheckRow: ThemedView {
    private let box = UIView()
    private let tick = UIImageView()
    private let label = UILabel()
    private var linkRange: NSRange?

    var isOn: Bool {
        didSet { apply(); onChange?() }
    }

    var onChange: (() -> Void)?
    var onLink: (() -> Void)?

    var hasError = false { didSet { refresh() } }

    init(theme: SheetTheme, text: String, link: String? = nil, isOn: Bool) {
        self.isOn = isOn
        super.init(theme: theme)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = link.map { "\(text) \($0)" } ?? text

        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer.cornerRadius = 7
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 1.5
        tick.image = Glyph.image("checkmark", size: 12, weight: .bold)
        tick.contentMode = .center
        tick.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tick)

        let body = NSMutableAttributedString(string: text, attributes: [.foregroundColor: theme.secondary])
        if let link {
            body.append(NSAttributedString(string: " "))
            linkRange = NSRange(location: body.length, length: (link as NSString).length)
            body.append(NSAttributedString(string: link, attributes: [
                .foregroundColor: theme.text, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: theme.tertiary,
            ]))
        }
        body.addAttribute(.font, value: theme.font(14, .regular, style: .subheadline), range: NSRange(location: 0, length: body.length))
        label.attributedText = body
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 24),
            box.heightAnchor.constraint(equalToConstant: 24),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tick.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            tick.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        apply()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if let linkRange, let index = characterIndex(at: gesture.location(in: label)), NSLocationInRange(index, linkRange) {
            onLink?()
        } else {
            isOn.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    override func accessibilityActivate() -> Bool {
        isOn.toggle()
        return true
    }

    /// Which character of the label a touch landed on, laid out the way the label lays it out.
    private func characterIndex(at point: CGPoint) -> Int? {
        guard let text = label.attributedText, label.bounds.contains(point) else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = label.numberOfLines
        container.lineBreakMode = label.lineBreakMode
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyph = layout.glyphIndex(for: point, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    private func apply() {
        tick.isHidden = !isOn
        accessibilityValue = isOn ? "1" : "0"
        if isOn { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
        if isOn { hasError = false } else { refresh() }
    }

    override func refresh() {
        box.backgroundColor = isOn ? theme.primary : .clear
        tick.tintColor = theme.onPrimary
        box.layer.borderColor = cg(isOn ? theme.primary : (hasError ? theme.danger : theme.tertiary))
    }
}

// MARK: - Choices

/// One way to pay among several: a balance, a saved card, another card.
final class ChoiceRow: UIControl {
    private let theme: SheetTheme
    private let radio = UIView()
    private let dot = UIView()
    private let title = UILabel()
    private let detail = UILabel()

    override var isSelected: Bool { didSet { apply() } }
    override var isEnabled: Bool { didSet { apply() } }
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? theme.line : .clear } }

    init(theme: SheetTheme, title text: String, detail sub: String?, latinTitle: Bool = false, trailing: UIView? = nil) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityLabel = [text, sub].compactMap { $0 }.joined(separator: ", ")

        radio.layer.cornerRadius = 11
        radio.layer.borderWidth = 1.5
        radio.isUserInteractionEnabled = false
        radio.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        radio.addSubview(dot)

        title.text = text
        title.font = theme.font(16, .medium, style: .callout, digits: true)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = theme.text
        title.numberOfLines = 2
        if latinTitle { title.semanticContentAttribute = .forceLeftToRight }
        detail.text = sub
        detail.font = theme.font(13, .regular, style: .footnote, digits: true)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = theme.secondary
        detail.numberOfLines = 0
        detail.isHidden = sub == nil
        let column = UIStackView(arrangedSubviews: [title, detail])
        column.axis = .vertical
        column.spacing = 2
        let row = UIStackView(arrangedSubviews: [radio, column])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        if let trailing {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(trailing)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            radio.widthAnchor.constraint(equalToConstant: 22),
            radio.heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: radio.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: radio.centerYAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        apply()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setDetail(_ text: String?) {
        detail.text = text
        detail.isHidden = text == nil
    }

    private func apply() {
        let traits = traitCollection
        radio.layer.borderColor = (isSelected ? theme.primary : theme.tertiary).resolvedColor(with: traits).cgColor
        radio.backgroundColor = isSelected ? theme.primary : .clear
        dot.backgroundColor = isSelected ? theme.onPrimary : .clear
        alpha = isEnabled ? 1 : 0.45
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        apply()
    }
}

/// Rows in one bordered box with a hairline between them: the ways to pay, the lines of an order.
final class GroupBox: ThemedView {
    let column = UIStackView()

    init(theme: SheetTheme, rows: [UIView] = [], filled: Bool = true) {
        super.init(theme: theme)
        backgroundColor = filled ? theme.surface : .clear
        layer.cornerRadius = theme.cardRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = filled ? 0 : 1
        clipsToBounds = true
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        rows.forEach(add)
    }

    func add(_ row: UIView) {
        if !column.arrangedSubviews.isEmpty {
            let line = UIView()
            line.backgroundColor = theme.line
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            column.addArrangedSubview(line)
        }
        column.addArrangedSubview(row)
    }

    override func refresh() { layer.borderColor = cg(theme.border) }
}

/// Labels and their values, one per row (a reference, a date, an amount).
final class RowsCard: ThemedView {
    init(context: SheetContext, rows: [Sheet.Row]) {
        super.init(theme: context.theme)
        let box = GroupBox(theme: theme)
        for row in rows {
            let label = UILabel()
            label.text = row.label
            label.font = theme.font(14, .regular, style: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = theme.secondary
            label.numberOfLines = 0
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let value = UILabel()
            value.text = row.value
            value.font = row.mono ? theme.mono(13, .medium) : theme.font(14, .medium, style: .subheadline, digits: true)
            value.adjustsFontForContentSizeCategory = true
            value.textColor = theme.text
            value.numberOfLines = 0
            value.textAlignment = context.trailingAlignment
            value.lineBreakMode = row.mono ? .byCharWrapping : .byWordWrapping
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = UIStackView(arrangedSubviews: [label, value])
            line.axis = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 16
            line.isLayoutMarginsRelativeArrangement = true
            line.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            line.isAccessibilityElement = true
            line.accessibilityLabel = "\(row.label), \(row.value)"
            box.add(line)
        }
        addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

// MARK: - Small parts

/// The merchant's logo, or its initial until (or instead of) the logo.
final class AvatarView: ThemedView {
    private let initial = UILabel()
    private let picture = UIImageView()

    init(theme: SheetTheme, name: String, size: CGFloat = 56) {
        super.init(theme: theme)
        backgroundColor = theme.surface
        layer.cornerRadius = size * 0.28
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true
        isAccessibilityElement = false
        initial.text = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        initial.font = theme.font(size * 0.42, .semibold, style: .title2)
        initial.textColor = theme.secondary
        initial.textAlignment = .center
        picture.contentMode = .scaleAspectFill
        picture.backgroundColor = .white
        picture.isHidden = true
        for view in [initial, picture] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
    }

    func show(_ image: UIImage) {
        picture.image = image
        picture.alpha = 0
        picture.isHidden = false
        UIView.animate(withDuration: 0.2) { self.picture.alpha = 1 }
    }

    override func refresh() { layer.borderColor = cg(theme.line) }
}

/// A short status word in a capsule ("Test mode").
final class Chip: UIView {
    init(theme: SheetTheme, text: String, color: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = theme.soft(color, 0.14)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        let label = UILabel()
        label.text = text
        label.font = theme.font(12, .semibold, style: .caption1)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A sentence the payer should not miss, in a soft box of its tone: something that went wrong, something to know.
final class NoticeView: ThemedView {
    enum Tone { case danger, neutral }

    private let icon = UIImageView()
    private let label = UILabel()

    var text: String? {
        didSet { label.text = text }
    }

    init(theme: SheetTheme, tone: Tone, text: String? = nil, symbol: String? = nil) {
        super.init(theme: theme)
        let color = tone == .danger ? theme.danger : theme.secondary
        backgroundColor = tone == .danger ? theme.soft(theme.danger, 0.10) : theme.surface
        layer.cornerRadius = theme.radius
        layer.cornerCurve = .continuous
        icon.image = Glyph.image(symbol ?? (tone == .danger ? "exclamationmark.circle.fill" : "info.circle.fill"), size: 15)
        icon.tintColor = color
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.text = text
        label.font = theme.font(14, .regular, style: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = tone == .danger ? theme.danger : theme.text
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }
}

/// The marks of the two card networks, CIB and Edahabia. `show(_:)` keeps only the network of the number being typed.
final class BrandMarks: UIView {
    private let cib = UIImageView(image: SheetAssets.image("rais-cib"))
    private let edahabia = UIImageView(image: SheetAssets.image("rais-edahabia"))

    init(size: CGFloat = 26) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityLabel = "CIB, Edahabia"
        let row = UIStackView(arrangedSubviews: [cib, edahabia])
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for mark in [cib, edahabia] {
            mark.contentMode = .scaleAspectFit
            mark.backgroundColor = .white
            mark.layer.cornerRadius = size * 0.22
            mark.layer.cornerCurve = .continuous
            mark.layer.borderWidth = 0.5
            mark.layer.borderColor = UIColor(white: 0.5, alpha: 0.3).cgColor
            mark.clipsToBounds = true
            mark.widthAnchor.constraint(equalToConstant: size).isActive = true
            mark.heightAnchor.constraint(equalToConstant: size).isActive = true
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ brand: CardRules.Brand?) {
        let showCIB = brand != .edahabia
        let showEdahabia = brand != .cib
        guard cib.isHidden == showCIB || edahabia.isHidden == showEdahabia else { return }
        UIView.animate(withDuration: 0.18) {
            self.cib.isHidden = !showCIB
            self.cib.alpha = showCIB ? 1 : 0
            self.edahabia.isHidden = !showEdahabia
            self.edahabia.alpha = showEdahabia ? 1 : 0
        }
    }

    /// One mark, for a card that is already known.
    static func single(_ brand: String?, size: CGFloat = 26) -> UIView? {
        let known: CardRules.Brand?
        switch brand?.lowercased() {
        case "cib": known = .cib
        case "edahabia", "dahabia": known = .edahabia
        default: known = nil
        }
        guard let known else { return nil }
        let marks = BrandMarks(size: size)
        marks.cib.isHidden = known != .cib
        marks.edahabia.isHidden = known != .edahabia
        marks.accessibilityLabel = known == .cib ? "CIB" : "Edahabia"
        return marks
    }
}

/// The pictures the SDK ships (the card networks' marks).
enum SheetAssets {
    static func image(_ name: String) -> UIImage? { UIImage(named: name, in: Strings.resources, compatibleWith: nil) }
}

/// The sign of an outcome: a check, a cross, a clock, in a soft disc of its tone.
final class IconDisc: UIView {
    init(theme: SheetTheme, symbol: String, color: UIColor, size: CGFloat = 64) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = theme.soft(color, 0.13)
        layer.cornerRadius = size / 2
        isAccessibilityElement = false
        let icon = UIImageView(image: Glyph.image(symbol, size: size * 0.38, weight: .bold))
        icon.tintColor = color
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - The bank's code

/// The bank's one-time code: cells that mirror ONE real text field, so paste, the code suggested from a message, and Backspace all behave
/// as the system makes them.
final class CodeField: ThemedView, UITextFieldDelegate {
    private let field = UITextField()
    private var cells: [UILabel] = []
    private let length: Int

    var onChange: (() -> Void)?
    var hasError = false { didSet { refresh() } }

    var code: String {
        get { field.text ?? "" }
        set { field.text = String(CardRules.digits(newValue).prefix(length)); render() }
    }

    var isComplete: Bool { code.count == length }

    init(theme: SheetTheme, length: Int, label: String) {
        self.length = max(4, min(length, 8))
        super.init(theme: theme)
        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.delegate = self
        field.tintColor = .clear
        field.textColor = .clear
        field.accessibilityLabel = label
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        addSubview(field)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.semanticContentAttribute = .forceLeftToRight   // a code reads left to right in every language
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<self.length {
            let cell = UILabel()
            cell.font = theme.font(24, .semibold, style: .title2, digits: true)
            cell.textColor = theme.text
            cell.textAlignment = .center
            cell.backgroundColor = theme.surface
            cell.layer.cornerRadius = theme.radius
            cell.layer.cornerCurve = .continuous
            cell.layer.borderWidth = 1
            cell.clipsToBounds = true
            cell.isAccessibilityElement = false
            cells.append(cell)
            row.addArrangedSubview(cell)
            if self.length == 6, index == 2 { row.setCustomSpacing(18, after: cell) }
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 58),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        bringSubviewToFront(row)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus)))
    }

    @objc func focus() { field.becomeFirstResponder() }
    func blur() { field.resignFirstResponder() }

    var isLocked = false {
        didSet { field.isEnabled = !isLocked; alpha = isLocked ? 0.6 : 1 }
    }

    @objc private func edited() {
        let clean = String(CardRules.digits(field.text ?? "").prefix(length))
        if clean != field.text { field.text = clean }
        if hasError { hasError = false }
        render()
        onChange?()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // typing and deleting happen at the end only: there is no caret to move inside the cells
        let end = textField.endOfDocument
        textField.selectedTextRange = textField.textRange(from: end, to: end)
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { refresh() }
    func textFieldDidEndEditing(_ textField: UITextField) { refresh() }

    private func render() {
        let digits = Array(code)
        for (index, cell) in cells.enumerated() { cell.text = index < digits.count ? String(digits[index]) : "" }
        refresh()
    }

    override func refresh() {
        let active = field.isFirstResponder ? min(code.count, length - 1) : -1
        for (index, cell) in cells.enumerated() {
            let color = hasError ? theme.danger : (index == active ? theme.primary : theme.border)
            cell.layer.borderColor = cg(color)
            cell.layer.borderWidth = hasError || index == active ? 1.5 : 1
        }
    }

    /// A wrong code: the cells say no.
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 6, -4, 3, 0]
        animation.duration = 0.32
        layer.add(animation, forKey: "shake")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
