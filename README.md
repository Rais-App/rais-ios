# Raïs for iOS

The Raïs checkout, inside your iOS app, drawn with native controls: the payment and its details, the card fields (CIB and Edahabia), saved cards and the payer's Raïs balance, the bank's confirmation code, and the result with its receipt. No web page, no robot check to tick. Light and dark mode, English, French and Arabic, an appearance you can customize, and a typed result for your app.

- iOS 15+, Swift 5.9+, UIKit and SwiftUI
- No dependencies, no Raïs key in your app
- Documentation: <https://rais.app/sdk/ios> · API reference: <https://rais.app/docs/api> · Changelog: [CHANGELOG.md](CHANGELOG.md)

## How it works

```
your app ──(1) "pay for order 1042"──▶ your server ──(2) POST /payments (secret key)──▶ Raïs
your app ◀─(3) checkout_url ───────── your server
your app ──(4) RaisCheckout.present(checkoutURL)──▶ the payer pays in the checkout screen
your app ◀─(5) .completed / .cancelled / .failed
your app ──(6) "what is the status of order 1042?"──▶ your server (webhook / GET /payments/{id})
```

Your **server** creates the payment and owns the amount and the secret key. The app only receives the `checkout_url`. The result in step 5 is what the payer saw, not proof of payment: ship the order on step 6.

## Install

**Swift Package Manager**: Xcode ▸ File ▸ Add Package Dependencies…, enter `https://github.com/rais-app/rais-ios`, and add the `Rais` library to your app target. Or in `Package.swift`:

```swift
.package(url: "https://github.com/rais-app/rais-ios", from: "1.0.0")
```

**CocoaPods**: `pod 'Rais', '~> 1.0'`

## Show the checkout

```swift
import Rais

let checkout = RaisCheckout(checkoutURL: checkoutURL)   // the checkout_url from your server
checkout.present(from: self) { result in
    switch result {
    case .completed(let payment):  // paid: payment.id, payment.reference, payment.orderNumber
        askMyServerAbout(payment.id)
    case .cancelled:               // the payer closed the checkout
        break
    case .failed(let failure):     // failure.code: .invalidURL, .loadFailed, .declined, .expired, .cannotPresent
        show(failure.message)
    }
}
```

`async/await`: `let result = await checkout.present(from: self)`.

| Result | When | What to do |
|---|---|---|
| `.completed(payment)` | the payer paid and saw the receipt. `payment.id` is the payment's id, `payment.reference` is the `reference` you gave it (`nil` when you gave none), `payment.orderNumber` is on the receipt | ask **your server** for the order's real status |
| `.cancelled` | the payer closed the checkout (or went back to your app) without paying | nothing was charged; offer to try again |
| `.failed` with `.declined` | the payer saw the bank's refusal (or an error) and left; `failure.paymentID` names the payment | show `failure.message`; your server knows the final state |
| `.failed` with `.expired` | the payment expired before it was paid | create a new payment |
| `.failed` with `.loadFailed` | the checkout page could not be loaded and the payer closed the screen | check the connection; offer to try again |
| `.failed` with `.invalidURL` | `checkoutURL` is not an `https` address on `rais.app` (or a trusted host) | check the `checkout_url` your server sent |
| `.failed` with `.cannotPresent` | there was no screen on top to present from | present from a view controller that is on screen |

### SwiftUI

```swift
Button("Pay") { showCheckout = true }
    .raisCheckout(isPresented: $showCheckout, checkoutURL: checkoutURL) { result in
        if case .completed(let payment) = result { askMyServerAbout(payment.id) }
    }
```

## Customize it

Everything is optional. What you leave `nil` keeps Raïs' value, which already has a light and a dark palette.

```swift
var configuration = RaisCheckout.Configuration()
configuration.appearance.colorScheme = .automatic             // .light, .dark, or follow the device (default)
configuration.appearance.colors.primary = UIColor(named: "Brand")   // the pay button and the accents
configuration.appearance.colors.background = UIColor(named: "Background")
configuration.appearance.cornerRadius = 12                    // buttons and fields (0–24, default 12)
configuration.appearance.fontFamily = .serif                  // .default and .system (San Francisco), .serif, .monospace
configuration.language = .french                              // .automatic (default), .english, .french, .arabic
configuration.presentationStyle = .sheet                      // .fullScreen (default)

let checkout = RaisCheckout(checkoutURL: checkoutURL, configuration: configuration)
```

| `Appearance.Colors` | What it colors |
|---|---|
| `primary` | the pay button, the accents and the focus ring of the fields |
| `onPrimary` | text on `primary` (when `nil`, black or white for the best contrast) |
| `background`, `surface` | the page, and cards on it |
| `text`, `textSecondary` | main text, and labels and hints |
| `border` | the border of the fields |
| `danger`, `success` | errors, and the success state |

Colors may be dynamic `UIColor`s: the SDK reads them for the scheme on screen and updates the open page when the device switches between light and dark.

| `Configuration` | Default | |
|---|---|---|
| `appearance` | untouched | colors, `cornerRadius`, `fontFamily`, `colorScheme` |
| `style` | `.native` | `.web` shows the hosted checkout page in a web view instead |
| `language` | `.automatic` | the payer can still switch on the page |
| `presentationStyle` | `.fullScreen` | or `.sheet` |
| `showsCloseButton` | `true` | the system always lets the payer leave; keep it unless you draw your own |
| `returnURLScheme` | `nil` | your app's URL scheme, when the payment's `success_url` / `cancel_url` are deep links |
| `additionalTrustedHosts` | `[]` | extra hosts allowed as a checkout (staging); `rais.app` and loopback are always allowed |

## What the payer sees

- **The payment**: the store (its logo), the amount, the description, and "View details" for the order's lines, the reference and the validity.
- **The ways to pay**: a card typed now (number, expiry, CVC, name: formatted as typed, checked before anything is sent), the cards a store keeps for its customer, and, for a payer the checkout has identified, their Raïs balance and the cards of their Raïs account. The optional receipt address, "save this card" and the terms are there when the payment calls for them.
- **The bank's code** (3-D Secure), in six cells, with the system's own code suggestion and paste.
- **The result**: paid, refused (with the bank's reason), expired, cancelled, or still being confirmed with the bank (the screen keeps asking). A paid payment offers its PDF receipt (view, share, print) and the receipt by e-mail.

The words, the amounts and every rule come from Raïs' server, in the payer's language, so the screen always says what the hosted page says. A payment whose card must be typed on the bank's own page (`mode: "raw"`) is shown as that page, in the same screen, and so is any payment on a server that has no native checkout: the SDK falls back by itself.

To offer "Open in the Raïs app" to payers who have it, add `rais` to `LSApplicationQueriesSchemes` in your Info.plist. Without it the button is simply not shown.

## Security

- The checkout address must be `https://…rais.app` (or a host you list in `additionalTrustedHosts`). Plain `http` is accepted for `localhost` and `127.0.0.1` only, so you can test against a local server (add `NSAllowsLocalNetworking` to your test app's App Transport Security settings).
- Card details go from the fields straight to Raïs over TLS, in the one request that pays. They are never written to disk, never logged, and never handed to your app: the SDK's result carries the payment's id, reference and order number only.
- The checkout runs in its own in-memory session: its cookies (who is paying, the bank's step in progress) are gone when the screen closes.
- The server's robot check still applies: the SDK solves its proof of work in the background, so a payer has nothing to tick and a script gains nothing by pretending to be the SDK.
- Links (the terms, the Raïs site) open in Safari, so the payer can always come back.
- If you want the payment to run outside your app's process entirely, use the system browser instead (see the [mobile guide](https://rais.app/docs/mobile)).

## Try it

The `Example` app has every option on one screen. Start the SDK's test rig or paste a `checkout_url` from your sandbox:

```sh
cd Example && xcodegen generate && open RaisExample.xcodeproj
```

## License

MIT. See [LICENSE](LICENSE).
