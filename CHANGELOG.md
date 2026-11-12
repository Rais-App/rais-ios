# Changelog

All notable changes to the Raïs iOS SDK. The SDK follows [semantic versioning](https://semver.org). The checkout page itself is hosted by Raïs and improves without an SDK release; changes to what the page sends the app are announced here first.

## 1.0.0

First release.

- `RaisCheckout`: shows a payment's checkout in a native screen (UIKit `present(from:)`, async `present(from:)`, and a SwiftUI `.raisCheckout` modifier) and returns `.completed`, `.cancelled` or `.failed`.
- The checkout is drawn with native controls (`Configuration.style = .native`, the default): the payment and its details, card fields for CIB and Edahabia, a store's saved cards, the payer's Raïs balance and cards, the receipt address, the bank's confirmation code, and the result with its PDF receipt and the receipt by e-mail. It reads `GET /pay/{id}/sheet` and makes the hosted page's own calls. No robot check is shown: its proof of work is solved in the background.
- `Configuration.style = .web` shows the hosted page in a web view instead. The native screen also falls back to it by itself for a payment whose card is typed on the bank's own page and for a server without a native checkout.
- English, French and Arabic (right to left), following `Configuration.language`, else the payment and the device.
- Light and dark mode, following the device live or fixed with `colorScheme`.
- `Appearance`: colors (dynamic `UIColor`s accepted), corner radius, font family. `Configuration`: language, presentation style, close button, return URL scheme, additional trusted hosts.
- The keyboard never covers anything: the pay button sits above it, and in the web checkout the web view is pinned above it, so the page never jumps.
- The checkout address is validated (https on `rais.app`, or loopback for testing); in the web checkout the page's bridge to the app is limited to the checkout's own origin.
