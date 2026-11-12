import Foundation

extension RaisCheckout {
    /// How the checkout ended.
    public enum Result {
        /// The payer paid. This is what the page showed, not proof: **confirm the payment on your server** (signed webhook, or
        /// `GET /payments/{id}`) before you ship anything.
        case completed(Payment)
        /// The payer left without paying, or chose to go back.
        case cancelled
        /// The checkout could not be shown, or the payment was declined or expired.
        case failed(Failure)
    }

    /// The payment the payer paid.
    public struct Payment: Equatable {
        /// The Raïs payment id (the `id` of the payment your server created).
        public let id: String
        /// The `reference` you gave the payment, when you gave one.
        public let reference: String?
        /// The Raïs order number, as printed on the receipt.
        public let orderNumber: String?
    }

    /// Why the checkout did not complete.
    public struct Failure: Error, LocalizedError, Equatable {
        public enum Code: String {
            /// The URL is not a Raïs checkout address (not https, or not a trusted host).
            case invalidURL
            /// The page could not be loaded (no network, server unreachable).
            case loadFailed
            /// The bank declined the payment, or it ended in an error.
            case declined
            /// The payment expired before it was paid.
            case expired
            /// The checkout could not be presented (no view controller to present from).
            case cannotPresent
        }

        public let code: Code
        public let message: String
        /// The payment id when the failure came from a payment that exists.
        public let paymentID: String?

        public var errorDescription: String? { message }
    }
}
