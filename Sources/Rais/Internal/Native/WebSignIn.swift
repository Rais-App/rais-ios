import AuthenticationServices
import UIKit

/// "Sign in with Raïs" for a payer who does not have the Raïs app: the Raïs website's own sign-in (password, Apple or Google, whatever the
/// payer uses there), shown by the system in a sheet that shares Safari's sign-ins, like PayPal's. The checkout hands the answer back on a one-time
/// scheme that only this sign-in listens to; nothing is typed into the app and the app never sees a password.
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome {
        /// The payer session of this payment, to keep as the page's own cookie.
        case signedIn(String)
        case cancelled
        case failed
    }

    private var session: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    /// A scheme made up for this sign-in only (the checkout accepts `raiscb-` and 8 to 40 lower-case letters or digits).
    static func makeScheme() -> String {
        "raiscb-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
    }

    func start(url: URL, scheme: String, anchor: UIWindow?, completion: @escaping (Outcome) -> Void) {
        self.anchor = anchor
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
            DispatchQueue.main.async {
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    return completion(cancelled ? .cancelled : .failed)
                }
                guard let callback, callback.host == "signed-in",
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      let value = items.first(where: { $0.name == "s" })?.value, !value.isEmpty else { return completion(.failed) }
                completion(.signedIn(value))
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false   // the sign-ins the payer already has in Safari work here too
        self.session = session
        if !session.start() { completion(.failed) }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
