import CoreText
import UIKit

/// The look of the native checkout: Raïs' own palette (the hosted page's tokens, light and dark), with whatever the app set in
/// `RaisCheckout.Appearance` on top. Every color is dynamic, so the screen follows the device live; layers, which hold fixed colors, are
/// refreshed by the views that own them (`ThemedView`).
struct SheetTheme {
    let primary: UIColor
    let onPrimary: UIColor
    let background: UIColor
    /// Fields, cards and rows on the background.
    let surface: UIColor
    let text: UIColor
    let secondary: UIColor
    /// Hints and placeholders.
    let tertiary: UIColor
    /// Hairlines between rows.
    let line: UIColor
    /// The border of fields and choices.
    let border: UIColor
    let danger: UIColor
    let success: UIColor
    let warning: UIColor
    /// The corner radius of buttons and fields; cards are a little rounder.
    let radius: CGFloat
    private let design: UIFontDescriptor.SystemDesign
    private let provider: ((CGFloat, UIFont.Weight) -> UIFont?)?

    var cardRadius: CGFloat { radius == 0 ? 0 : radius + 4 }

    init(_ appearance: RaisCheckout.Appearance) {
        func pair(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> UIColor {
            UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha.1) : UIColor(hex: light, alpha: alpha.0) }
        }
        let colors = appearance.colors
        let background = colors.background ?? pair(0xFFFFFF, 0x0A0A0A)
        let text = colors.text ?? pair(0x17181A, 0xFFFFFF)
        let primary = colors.primary ?? pair(0x17181A, 0xFFFFFF)
        self.background = background
        self.text = text
        self.primary = primary
        onPrimary = colors.onPrimary ?? UIColor { traits in
            var white: CGFloat = 0
            var components: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
            let resolved = primary.resolvedColor(with: traits)
            if resolved.getRed(&components.0, green: &components.1, blue: &components.2, alpha: nil) {
                white = 0.299 * components.0 + 0.587 * components.1 + 0.114 * components.2
            } else {
                resolved.getWhite(&white, alpha: nil)
            }
            return white > 0.6 ? UIColor(hex: 0x0A0A0A) : .white
        }
        surface = colors.surface ?? pair(0xF7F7F6, 0x151517)
        secondary = colors.textSecondary ?? pair(0x5C5B56, 0x9A9A9A)
        tertiary = UIColor { text.resolvedColor(with: $0).withAlphaComponent(0.42) }
        line = UIColor { text.resolvedColor(with: $0).withAlphaComponent(0.10) }
        border = colors.border ?? UIColor { text.resolvedColor(with: $0).withAlphaComponent(0.16) }
        danger = colors.danger ?? pair(0xC4202E, 0xFF7B86)
        success = colors.success ?? pair(0x147A39, 0x4ADE80)
        warning = pair(0x9A5D06, 0xFBBF24)
        radius = min(max(appearance.cornerRadius ?? 12, 0), 24)
        provider = appearance.fontProvider
        switch appearance.fontFamily {
        case .default, .system: design = .default
        case .serif: design = .serif
        case .monospace: design = .monospaced
        }
    }

    /// `color` as a soft fill behind text of the same color (a notice, the disc of an icon).
    func soft(_ color: UIColor, _ amount: CGFloat = 0.12) -> UIColor {
        UIColor { color.resolvedColor(with: $0).withAlphaComponent(amount) }
    }

    /// A font of the app's chosen family that grows with the device's text size. `digits`: figures of equal width (amounts, card numbers).
    func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body, digits: Bool = false) -> UIFont {
        if let own = provider?(size, weight) {
            var font = own
            if digits {
                font = UIFont(descriptor: own.fontDescriptor.addingAttributes([.featureSettings: [[
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ]]]), size: size)
            }
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: size * 1.5)
        }
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if design != .default, let designed = descriptor.withDesign(design) { descriptor = designed }
        if digits {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]]])
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: size), maximumPointSize: size * 1.5)
    }

    /// Letters and figures of equal width: a reference, an order number.
    func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: weight), maximumPointSize: size * 1.5)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A view that owns layer colors: `refresh()` runs when it is first shown and whenever the device switches between light and dark.
class ThemedView: UIView {
    let theme: SheetTheme

    init(theme: SheetTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the colors that layers hold. Called with the view's own traits in force.
    func refresh() {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refresh() }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.hasDifferentColorAppearance(comparedTo: traitCollection) ?? true { refresh() }
    }

    func cg(_ color: UIColor) -> CGColor { color.resolvedColor(with: traitCollection).cgColor }
}

/// The words the SDK draws itself, as SF Symbols: one place, so every screen uses the same glyph for the same thing.
enum Glyph {
    static func image(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// The server names an outcome's icon in the page's words.
    static func symbol(forOutcome icon: String) -> String {
        switch icon {
        case "check": return "checkmark"
        case "x": return "xmark"
        case "clock": return "clock"
        default: return "exclamationmark"
        }
    }
}
