import UIKit

extension RaisCheckout {
    /// The look of the checkout page, in the spirit of Stripe's `PaymentSheet.Appearance`.
    ///
    /// Everything is optional. A property you leave `nil` keeps Raïs' own value, which already has a light and a dark palette,
    /// so you can change just the accent color, or everything.
    ///
    /// ```swift
    /// var appearance = RaisCheckout.Appearance()
    /// appearance.colors.primary = UIColor(red: 0.36, green: 0.27, blue: 0.93, alpha: 1)
    /// appearance.cornerRadius = 12
    /// appearance.colorScheme = .automatic
    /// ```
    ///
    /// A color can be a dynamic `UIColor` (for example `UIColor { $0.userInterfaceStyle == .dark ? … : … }`): the SDK reads it for the
    /// scheme that is on screen and updates the page when the device switches between light and dark.
    public struct Appearance {
        /// Which palette the page uses.
        public enum ColorScheme {
            /// Follows the device, live (the default).
            case automatic
            case light
            case dark
        }

        /// The typeface of the page. Only fonts that exist on every device can be named; custom font files of your app are not
        /// visible to a web page.
        public enum FontFamily: String {
            /// Raïs' own typeface (Inter, and 29LT Bukra for Arabic).
            case `default`
            /// The device's system font (San Francisco).
            case system
            case serif
            case monospace
        }

        /// The colors of the page. `nil` keeps Raïs' value for the current palette.
        public struct Colors {
            /// The pay button and the accents of the page.
            public var primary: UIColor?
            /// The text and icons on top of `primary`. When `nil`, black or white is chosen for the best contrast.
            public var onPrimary: UIColor?
            /// The page background.
            public var background: UIColor?
            /// Cards and panels on top of the background.
            public var surface: UIColor?
            /// The main text.
            public var text: UIColor?
            /// Labels, hints and secondary text.
            public var textSecondary: UIColor?
            /// The border of the input fields.
            public var border: UIColor?
            /// Errors and the failure state.
            public var danger: UIColor?
            /// The success state.
            public var success: UIColor?

            public init() {}
        }

        public var colorScheme: ColorScheme = .automatic
        public var colors = Colors()
        /// The corner radius of buttons and input fields, in points (0 to 24). Cards and dialogs follow it proportionally.
        public var cornerRadius: CGFloat?
        public var fontFamily: FontFamily = .default

        public init() {}
    }
}

// MARK: - What the page receives

extension RaisCheckout.Appearance {
    /// The palette in force for `traits`: `colorScheme` decides, or the device when it is `.automatic`.
    func effectiveStyle(for traits: UITraitCollection) -> UIUserInterfaceStyle {
        switch colorScheme {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return traits.userInterfaceStyle == .dark ? .dark : .light
        }
    }

    /// The appearance as the page understands it, with every color read for `style` and written as `#rrggbb` (or `#rrggbbaa`).
    func payload(style: UIUserInterfaceStyle) -> [String: Any] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var colorMap: [String: String] = [:]
        let pairs: [(String, UIColor?)] = [
            ("primary", colors.primary), ("onPrimary", colors.onPrimary), ("background", colors.background),
            ("surface", colors.surface), ("text", colors.text), ("textSecondary", colors.textSecondary),
            ("border", colors.border), ("danger", colors.danger), ("success", colors.success),
        ]
        for (name, color) in pairs {
            if let color, let hex = color.raisHex(in: traits) { colorMap[name] = hex }
        }
        var result: [String: Any] = [:]
        if !colorMap.isEmpty { result["colors"] = colorMap }
        if let cornerRadius { result["cornerRadius"] = Double(min(max(cornerRadius, 0), 24)) }
        if fontFamily != .default { result["fontFamily"] = fontFamily.rawValue }
        return result
    }

    /// The color the native container paints behind the page: what the page will show, so nothing flashes while it loads.
    func backgroundColor(style: UIUserInterfaceStyle) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: style)
        if let custom = colors.background { return custom.resolvedColor(with: traits) }
        // tokens.css: --bg
        return style == .dark ? UIColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1) : .white
    }
}

extension UIColor {
    /// This color with `amount` (0 to 1) of `other` mixed in, opaque, in sRGB.
    func raisBlend(with other: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1), other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    /// `#rrggbb`, or `#rrggbbaa` when not opaque, in sRGB, read for `traits`. `nil` when the color has no RGB value.
    func raisHex(in traits: UITraitCollection) -> String? {
        let resolved = resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
        return alpha < 0.999 ? base + String(format: "%02x", byte(alpha)) : base
    }
}
