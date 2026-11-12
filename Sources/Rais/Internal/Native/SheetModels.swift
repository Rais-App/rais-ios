import Foundation

/// The checkout as data: what `GET /pay/{id}/sheet` answers. The server decides which state a payment is in, writes every amount and
/// every sentence in the payer's language, and the screen draws it. Nothing here is computed on the phone.
struct Sheet: Decodable {
    enum State: String, Decodable {
        /// The payment can be paid: `pay` says how.
        case pay
        /// The payment is paid, closed, blocked or being confirmed: `result` says what became of it.
        case result
        /// The link names no payment.
        case notFound = "not_found"
    }

    let state: State
    let language: String
    let rtl: Bool
    let sandbox: Bool
    let payment: Payment?
    let merchant: Merchant?
    let text: [String: String]
    let pay: Pay?
    let result: Outcome?
    /// `not_found` only.
    let title: String?
    let lead: String?

    struct Payment: Decodable {
        let id: String
        let amount: Int
        let amountText: String
        let amountNumber: String
        let currency: String
        let description: String?
        let lines: [Line]
        let adjustmentText: String?
        let details: [Row]

        enum CodingKeys: String, CodingKey {
            case id, amount, currency, description, lines, details
            case amountText = "amount_text", amountNumber = "amount_number", adjustmentText = "adjustment_text"
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            id = try box.decode(String.self, forKey: .id)
            amount = try box.decode(Int.self, forKey: .amount)
            amountText = try box.decode(String.self, forKey: .amountText)
            amountNumber = try box.decodeIfPresent(String.self, forKey: .amountNumber) ?? amountText
            currency = try box.decodeIfPresent(String.self, forKey: .currency) ?? ""
            description = try box.decodeIfPresent(String.self, forKey: .description)
            lines = try box.decodeIfPresent([Line].self, forKey: .lines) ?? []
            adjustmentText = try box.decodeIfPresent(String.self, forKey: .adjustmentText)
            details = try box.decodeIfPresent([Row].self, forKey: .details) ?? []
        }
    }

    struct Line: Decodable {
        let name: String
        let description: String?
        let quantity: String?
        let totalText: String

        enum CodingKeys: String, CodingKey {
            case name, description, quantity
            case totalText = "total_text"
        }
    }

    /// One label and its value in a list of details.
    struct Row: Decodable {
        let label: String
        let value: String
        let mono: Bool

        enum CodingKeys: String, CodingKey { case label, value, mono }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            label = try box.decode(String.self, forKey: .label)
            value = try box.decode(String.self, forKey: .value)
            mono = try box.decodeIfPresent(Bool.self, forKey: .mono) ?? false
        }
    }

    struct Merchant: Decodable {
        let name: String
        let logoURL: URL?
        let website: String?

        enum CodingKeys: String, CodingKey {
            case name, website
            case logoURL = "logo_url"
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            name = try box.decode(String.self, forKey: .name)
            website = try box.decodeIfPresent(String.self, forKey: .website)
            logoURL = (try box.decodeIfPresent(String.self, forKey: .logoURL)).flatMap { URL(string: $0) }
        }
    }

    struct Pay: Decodable {
        /// `custom`: Raïs takes the card (this screen). `raw`: the bank's own page takes it (shown in the web checkout).
        let mode: String
        let captcha: Bool
        let sessionSeconds: TimeInterval
        let otpLength: Int
        let payer: Payer?
        let balance: Balance?
        let cards: [Card]
        let chosen: String?
        let appURL: URL?
        let save: Save?
        let receiptEmail: Bool
        let termsURL: URL?
        let otpPending: Bool

        struct Payer: Decodable {
            let firstName: String
            enum CodingKeys: String, CodingKey { case firstName = "first_name" }
        }

        struct Balance: Decodable {
            let text: String
            let enough: Bool
            let topupURL: URL?
            let shortText: String?

            enum CodingKeys: String, CodingKey {
                case text, enough
                case topupURL = "topup_url", shortText = "short_text"
            }

            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: CodingKeys.self)
                text = try box.decode(String.self, forKey: .text)
                enough = try box.decodeIfPresent(Bool.self, forKey: .enough) ?? false
                topupURL = (try box.decodeIfPresent(String.self, forKey: .topupURL)).flatMap { URL(string: $0) }
                shortText = try box.decodeIfPresent(String.self, forKey: .shortText)
            }
        }

        struct Card: Decodable, Equatable {
            /// `wallet`: a card of the payer's Raïs account. `saved`: a card the store keeps for its customer.
            enum Kind: String, Decodable { case wallet, saved }

            let id: String
            let kind: Kind
            let last4: String
            let expiry: String
            let brand: String?
            let needsCVC: Bool

            enum CodingKeys: String, CodingKey {
                case id, kind, last4, expiry, brand
                case needsCVC = "needs_cvc"
            }
        }

        struct Save: Decodable {
            let label: String
            let checked: Bool
        }

        enum CodingKeys: String, CodingKey {
            case mode, captcha, payer, balance, cards, chosen, save
            case sessionSeconds = "session_seconds", otpLength = "otp_length", appURL = "app_url", receiptEmail = "receipt_email"
            case termsURL = "terms_url", otpPending = "otp_pending"
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            mode = try box.decodeIfPresent(String.self, forKey: .mode) ?? "custom"
            captcha = try box.decodeIfPresent(Bool.self, forKey: .captcha) ?? false
            sessionSeconds = try box.decodeIfPresent(TimeInterval.self, forKey: .sessionSeconds) ?? 570
            otpLength = try box.decodeIfPresent(Int.self, forKey: .otpLength) ?? 6
            payer = try box.decodeIfPresent(Payer.self, forKey: .payer)
            balance = try box.decodeIfPresent(Balance.self, forKey: .balance)
            cards = try box.decodeIfPresent([Card].self, forKey: .cards) ?? []
            chosen = try box.decodeIfPresent(String.self, forKey: .chosen)
            appURL = (try box.decodeIfPresent(String.self, forKey: .appURL)).flatMap { URL(string: $0) }
            save = try box.decodeIfPresent(Save.self, forKey: .save)
            receiptEmail = try box.decodeIfPresent(Bool.self, forKey: .receiptEmail) ?? false
            termsURL = (try box.decodeIfPresent(String.self, forKey: .termsURL)).flatMap { URL(string: $0) }
            otpPending = try box.decodeIfPresent(Bool.self, forKey: .otpPending) ?? false
        }
    }

    /// What became of a payment, already worded: the screen draws it as it is.
    struct Outcome: Decodable {
        enum Tone: String, Decodable { case ok, bad, neutral }

        let tone: Tone
        let icon: String
        let title: String
        let lead: String?
        let note: String?
        let rows: [Row]
        let support: String?
        let receipt: Receipt?
        let retry: Bool
        let contactEmail: String?
        let outcome: Reported?
        let confirming: Confirming?

        struct Receipt: Decodable {
            let url: URL
            let mail: Mail?

            struct Mail: Decodable {
                let sent: Bool
                let to: String?
                let known: String?
            }
        }

        /// How the payment ended, for the app that opened the checkout.
        struct Reported: Decodable {
            let status: String
            let paymentID: String
            let reference: String?
            let orderNumber: String?

            enum CodingKeys: String, CodingKey {
                case status, reference
                case paymentID = "payment_id", orderNumber = "order_number"
            }
        }

        struct Confirming: Decodable {
            let statusURL: URL
            let resultURL: URL

            enum CodingKeys: String, CodingKey {
                case statusURL = "status_url", resultURL = "result_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tone, icon, title, lead, note, rows, support, receipt, retry, outcome, confirming
            case contactEmail = "contact_email"
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            tone = (try? box.decode(Tone.self, forKey: .tone)) ?? .neutral
            icon = try box.decodeIfPresent(String.self, forKey: .icon) ?? "alert"
            title = try box.decode(String.self, forKey: .title)
            lead = try box.decodeIfPresent(String.self, forKey: .lead)
            note = try box.decodeIfPresent(String.self, forKey: .note)
            rows = try box.decodeIfPresent([Row].self, forKey: .rows) ?? []
            support = try box.decodeIfPresent(String.self, forKey: .support)
            receipt = try? box.decodeIfPresent(Receipt.self, forKey: .receipt)
            retry = try box.decodeIfPresent(Bool.self, forKey: .retry) ?? false
            contactEmail = try box.decodeIfPresent(String.self, forKey: .contactEmail)
            outcome = try box.decodeIfPresent(Reported.self, forKey: .outcome)
            confirming = try? box.decodeIfPresent(Confirming.self, forKey: .confirming)
        }
    }

    enum CodingKeys: String, CodingKey {
        case state, language, rtl, sandbox, payment, merchant, text, pay, result, title, lead
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        state = try box.decode(State.self, forKey: .state)
        language = try box.decodeIfPresent(String.self, forKey: .language) ?? "en"
        rtl = try box.decodeIfPresent(Bool.self, forKey: .rtl) ?? false
        sandbox = try box.decodeIfPresent(Bool.self, forKey: .sandbox) ?? false
        payment = try box.decodeIfPresent(Payment.self, forKey: .payment)
        merchant = try box.decodeIfPresent(Merchant.self, forKey: .merchant)
        text = try box.decodeIfPresent([String: String].self, forKey: .text) ?? [:]
        pay = try box.decodeIfPresent(Pay.self, forKey: .pay)
        result = try box.decodeIfPresent(Outcome.self, forKey: .result)
        title = try box.decodeIfPresent(String.self, forKey: .title)
        lead = try box.decodeIfPresent(String.self, forKey: .lead)
    }
}

/// The server's words for this payer (`Sheet.text`): `words["pay.card_number"]`, and `words("js.session", ["time": "9:41"])` for a sentence
/// with something only the screen knows.
struct Words {
    let table: [String: String]

    subscript(key: String) -> String { table[key] ?? "" }

    func callAsFunction(_ key: String, _ values: [String: String]) -> String {
        values.reduce(self[key]) { text, pair in text.replacingOccurrences(of: "{\(pair.key)}", with: pair.value) }
    }

    /// What the server said about a call it refused: our own words in the payer's language whenever it sent a code, else the sentence the
    /// bank's gateway wrote, as it came.
    func describing(_ refusal: CheckoutAPI.Refusal) -> String {
        if let code = refusal.code, let text = table["js.code.\(code)"], !text.isEmpty { return text }
        if refusal.code == nil, let message = refusal.message, !message.isEmpty { return message }
        return self["js.generic"]
    }
}
