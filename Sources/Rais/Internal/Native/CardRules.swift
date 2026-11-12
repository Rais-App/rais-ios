import Foundation

/// How the card fields read, write and judge what is typed. The same rules as the hosted page's script, so a card is accepted or refused the
/// same way on both. A check returns the key of the server's sentence about the problem (`Sheet.text`), or `nil` when there is none.
enum CardRules {
    static let panLength = 16      // CIB and Edahabia numbers have 16 digits: once they are all there, the next field takes over
    static let panMaximum = 19
    static let cvcLength = 3

    enum Brand: String { case cib, edahabia }

    /// The digits of a value, also when the keyboard wrote them as Arabic-Indic (٠-٩), Persian (۰-۹) or full-width digits.
    static func digits(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39: out.unicodeScalars.append(scalar)
            case 0x0660...0x0669: out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            case 0xFF10...0xFF19: out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            default: break
            }
        }
        return out
    }

    /// "6280581110007215" → "6280 5811 1000 7215".
    static func formatPAN(_ value: String) -> String {
        let number = String(digits(value).prefix(panMaximum))
        var out = ""
        for (index, character) in number.enumerated() {
            if index > 0, index % 4 == 0 { out.append(" ") }
            out.append(character)
        }
        return out
    }

    /// "1227" → "12 / 27"; a first digit above 1 is a month already ("5" → "05").
    static func formatExpiry(_ value: String) -> String {
        var number = String(digits(value).prefix(4))
        if number.count == 1, let first = number.first, first > "1" { number = "0" + number }
        guard number.count >= 2 else { return number }
        return number.prefix(2) + " / " + number.dropFirst(2)
    }

    /// 6280 is Edahabia, the rest of the 62 range CIB (as the server's own detection says).
    static func brand(of number: String) -> Brand? {
        if number.hasPrefix("6280") { return .edahabia }
        if number.hasPrefix("62") { return .cib }
        return nil
    }

    static func luhn(_ number: String) -> Bool {
        var sum = 0
        var alternate = false
        for character in number.reversed() {
            guard var digit = character.wholeNumberValue else { return false }
            if alternate {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
            alternate.toggle()
        }
        return !number.isEmpty && sum % 10 == 0
    }

    /// A name as the bank reads it: no accents, single spaces.
    static func cleanName(_ value: String) -> String {
        let plain = value.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x0300...0x036F).contains($0.value) }
        return String(String.UnicodeScalarView(plain)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The card as the bank masks it ("628058******7215"), in groups of four with dots: "6280 58•• •••• 7215".
    static func formatMasked(_ value: String?) -> String {
        let shown = (value ?? "").compactMap { character -> Character? in
            if character.isASCII, character.isNumber { return character }
            return "*•xX".contains(character) ? "•" : nil
        }
        var out = ""
        for (index, character) in shown.enumerated() {
            if index > 0, index % 4 == 0 { out.append(" ") }
            out.append(character)
        }
        return out
    }

    // MARK: Checks
    // `sandbox`: a test payment. The test gateway has cards that are expired or have a wrong check digit on purpose, and they must reach it
    // to be refused there, as a real answer.

    static func checkPAN(_ value: String, sandbox: Bool) -> String? {
        let number = digits(value)
        if number.isEmpty { return "js.pan_required" }
        if number.count < 13 || number.count > panMaximum { return "js.pan_invalid" }
        if !sandbox, !luhn(number) { return "js.pan_invalid" }
        return nil
    }

    static func checkExpiry(_ value: String, sandbox: Bool, now: Date = Date()) -> String? {
        let number = digits(value)
        if number.isEmpty { return "js.expiry_required" }
        guard number.count == 4, let month = Int(number.prefix(2)), let short = Int(number.suffix(2)) else { return "js.expiry_invalid" }
        if month < 1 || month > 12 { return "js.expiry_invalid" }
        if sandbox { return nil }
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        let year = 2000 + short
        if year < (today.year ?? 0) || (year == today.year && month < (today.month ?? 0)) { return "js.expiry_past" }
        return nil
    }

    static func checkCVC(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespaces)
        return code.count == cvcLength && code.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : "js.cvc_invalid"
    }

    static func checkName(_ value: String) -> String? {
        let name = cleanName(value)
        if name.isEmpty { return "js.name_required" }
        return name.range(of: "^[A-Za-z][A-Za-z0-9$)(\\-. ]{1,25}$", options: .regularExpression) != nil ? nil : "js.name_invalid"
    }

    /// The receipt address is optional: only what is typed is checked (the server is the authority and answers a wrong one too).
    static func checkEmail(_ value: String) -> String? {
        let address = value.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return nil }
        let pattern = "^[^@\\s<>()\\[\\]\\\\,;:\"]{1,64}@[^@\\s<>()\\[\\]\\\\,;:\"]+\\.[^@\\s<>()\\[\\]\\\\,;:\"]{2,}$"
        return address.count <= 254 && address.range(of: pattern, options: .regularExpression) != nil ? nil : "js.email_invalid"
    }
}

/// The card a payer typed, ready to be sent. Lives only for the request that sends it.
struct TypedCard {
    let pan: String
    let cvc: String
    let expiryMonth: String
    let expiryYear: String
    let holder: String
}
