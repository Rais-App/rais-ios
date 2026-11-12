import Rais
import SwiftUI
import UIKit

/// Every option of the SDK in one screen. Your server creates the payment; here you paste the `checkout_url` it returned.
///
/// For automated runs the screen also reads launch arguments: `-rais-url <checkout url>`, `-rais-scheme light|dark|automatic`,
/// `-rais-primary #5b5bd6`, `-rais-radius 12`, `-rais-lang fr`, `-rais-present YES` (present at launch), `-rais-autoclose 5` (close from code).
struct ContentView: View {
    private let defaults = UserDefaults.standard

    @State private var urlText = ""
    @State private var scheme: RaisCheckout.Appearance.ColorScheme = .automatic
    @State private var language: RaisCheckout.Language = .automatic
    @State private var customPrimary = false
    @State private var primary = Color(red: 0.36, green: 0.27, blue: 0.93)
    @State private var radius = 6.0
    @State private var customRadius = false
    @State private var font: RaisCheckout.Appearance.FontFamily = .default
    @State private var sheet = false
    @State private var closeButton = true
    @State private var present = false
    @State private var launched = false
    @State private var outcome = "No checkout yet"

    var body: some View {
        NavigationView {
            Form {
                Section("Checkout URL (from POST /payments)") {
                    TextField("https://pay.rais.app/pay/…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("url")
                }
                Section("Appearance") {
                    Picker("Color scheme", selection: $scheme) {
                        Text("Automatic").tag(RaisCheckout.Appearance.ColorScheme.automatic)
                        Text("Light").tag(RaisCheckout.Appearance.ColorScheme.light)
                        Text("Dark").tag(RaisCheckout.Appearance.ColorScheme.dark)
                    }
                    Toggle("Custom accent color", isOn: $customPrimary)
                    if customPrimary { ColorPicker("Primary", selection: $primary, supportsOpacity: false) }
                    Toggle("Custom corner radius", isOn: $customRadius)
                    if customRadius { Slider(value: $radius, in: 0...24, step: 1) { Text("Radius") } }
                    Picker("Font", selection: $font) {
                        Text("Raïs").tag(RaisCheckout.Appearance.FontFamily.default)
                        Text("System").tag(RaisCheckout.Appearance.FontFamily.system)
                        Text("Serif").tag(RaisCheckout.Appearance.FontFamily.serif)
                        Text("Monospace").tag(RaisCheckout.Appearance.FontFamily.monospace)
                    }
                }
                Section("Behavior") {
                    Picker("Language", selection: $language) {
                        ForEach(RaisCheckout.Language.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Toggle("Present as a sheet", isOn: $sheet)
                    Toggle("Close button", isOn: $closeButton)
                }
                Section {
                    Button("Pay (SwiftUI)") { present = true }
                        .accessibilityIdentifier("pay-swiftui")
                    Button("Pay (UIKit)") { presentWithUIKit() }
                        .accessibilityIdentifier("pay-uikit")
                    Text(outcome).font(.footnote).foregroundColor(.secondary).accessibilityIdentifier("outcome")
                }
            }
            .navigationTitle("Raïs SDK")
        }
        .navigationViewStyle(.stack)
        .raisCheckout(isPresented: $present, checkoutURL: URL(string: urlText), configuration: configuration, onCompletion: show)
        .onAppear(perform: applyLaunchArguments)
    }

    private var configuration: RaisCheckout.Configuration {
        var configuration = RaisCheckout.Configuration()
        configuration.appearance.colorScheme = scheme
        if customPrimary { configuration.appearance.colors.primary = UIColor(primary) }
        if customRadius { configuration.appearance.cornerRadius = CGFloat(radius) }
        configuration.appearance.fontFamily = font
        configuration.language = language
        configuration.presentationStyle = sheet ? .sheet : .fullScreen
        configuration.showsCloseButton = closeButton
        return configuration
    }

    private func presentWithUIKit() {
        guard let url = URL(string: urlText),
              let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first
        else { return outcome = "Enter a checkout URL first" }
        RaisCheckout(checkoutURL: url, configuration: configuration).present(from: root, completion: show)
    }

    private func show(_ result: RaisCheckout.Result) {
        switch result {
        case .completed(let payment): outcome = "Paid \(payment.id) \(payment.reference ?? "")"
        case .cancelled: outcome = "Cancelled"
        case .failed(let failure): outcome = "Failed (\(failure.code.rawValue)): \(failure.message)"
        }
    }

    private func applyLaunchArguments() {
        guard !launched else { return }   // `onAppear` runs again each time the checkout closes: launch arguments are for the launch only
        launched = true
        if let url = defaults.string(forKey: "rais-url") { urlText = url }
        switch defaults.string(forKey: "rais-scheme") {
        case "light": scheme = .light
        case "dark": scheme = .dark
        default: break
        }
        if let lang = defaults.string(forKey: "rais-lang"), let value = RaisCheckout.Language(rawValue: lang) { language = value }
        if let hex = defaults.string(forKey: "rais-primary"), let color = Color(hex: hex) { primary = color; customPrimary = true }
        if defaults.object(forKey: "rais-radius") != nil { radius = defaults.double(forKey: "rais-radius"); customRadius = true }
        if defaults.bool(forKey: "rais-present") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { present = true } }
        // `-rais-autoclose 5`: turn the binding off from code that many seconds after presenting (what an app does when its own state ends the payment)
        if defaults.object(forKey: "rais-autoclose") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + defaults.double(forKey: "rais-autoclose")) { present = false }
        }
    }
}

private extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
