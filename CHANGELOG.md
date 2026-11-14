# Changelog

All notable changes to the Raïs iOS SDK. The SDK follows [semantic versioning](https://semver.org). The checkout page itself is hosted by Raïs and improves without an SDK release; changes to what the page sends the app are announced here first.

## Unreleased

- Keyboard: a field typed in is always fully above the keyboard and the pay button. It is brought into view again once the keyboard has settled (or changed height), the last field on the page gets room to rise clear of the button, and the e-mail receipt form comes into view whole (its note and its Send button included).
- A development server on the local network works on a real phone: `additionalTrustedHosts` now accepts a private address (192.168.x.x, 10.x, 172.16-31.x, 100.64-127.x, `*.local`) over plain http. Public hosts still need https.
- `appearance.fontProvider`: the native checkout in the app's own typeface.
- The checkout scrolls under everything: nothing above the page but a glass close button (what scrolls under the status bar fades out), and the pay button sits in a floating pane of glass (Liquid Glass on iOS 26, the system's thin blur before).
- The "I accept the terms" checkbox is gone. "Save this card" is a switch.
- The ways to pay lead with their mark (the card's network, the Raïs mark) and the chosen one carries a check.
- `Configuration.merchantLogo`: a picture to show instead of the logo of the merchant's Raïs account.
- A top-up opened by the Raïs app offers the cards of the person's own Raïs account (server: `GET /pay/{id}/sheet` lists them for the top-up's owner, `POST /pay/{id}/process-wallet-card` charges one).

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
