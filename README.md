# Ratify Music iOS

A Capacitor 8 iOS app, shown on the home screen as **Ratify Music**. It loads
the published Base44 site on its custom domain, `https://ratifymusic.com`, and
adds two native pieces:

- **NativeMusicKit**: Apple Music authorization and full-song playback through
  Apple's MusicKit framework. It implements the bridge the site already has
  (`src/lib/nativeMusicKit.js` in the Base44 repo), so the site needs no
  changes. Inside this app the site's MusicKitContext uses it instead of
  MusicKit JS, whose authorization popup never returns inside a WebView.
- **Base44Auth**: the Apple, Google, Facebook and Microsoft sign-in buttons
  run in the system sign-in sheet (ASWebAuthenticationSession) and return to
  the app signed in. Google refuses OAuth inside WebViews.

The app does not bundle a build of the site. Anything published in Base44
reaches the app straight away, as it did with Base44's wrapper.

The site's previous address,
`master-ratify-music-v1production-copy.base44.app`, still serves the same
app. Links to it, including universal links from old emails, open the same
page on ratifymusic.com instead (`legacyHosts` in `capacitor.config.ts`). A
member's sign-in is kept per address, so anyone who used build 3.0 (1) signs
in once more.

## Store identity

| | |
|---|---|
| Bundle id | `com.base69900c52dad19ccce6c947de.app`, the id of the Base44-built app already in TestFlight |
| Team | `97Z6JVW7XJ` (Ratify LLC), as named in the site's apple-app-site-association |
| Name | Ratify Music on the home screen. The App Store and TestFlight name is set separately, in App Store Connect under App Information. |
| Devices | iPhone and iPad, portrait on iPhone |
| Minimum iOS | 15.0 |

Keeping the bundle id makes each build the next build of the existing app
record, with the same testers and the same App Store listing. It is also what
the site's apple-app-site-association already lists, which the sign-in sheet
and Password AutoFill rely on.

## How playback works

- **Authorization** uses MusicKit's `MusicAuthorization`. This is the system "Allow
  Ratify Music to access Apple Music?" prompt.
- **Subscription check** uses StoreKit's `SKCloudServiceController`.
- **Playback** uses the system application music player
  (`MPMusicPlayerController.applicationQueuePlayer`), by Apple Music catalog ID.
- **Albums** are expanded to their tracks through Apple's public iTunes lookup.

None of these needs a MusicKit developer token, so playback doesn't depend on
the MusicKit App Service on the App ID. Build 3.0 (2) used MusicKit catalog
requests, and those failed in TestFlight with `developerTokenRequestFailed`.

Full songs still need an Apple Music subscription on the device's Apple ID. That
Apple ID must also have opened the Music app once and accepted Apple Music's
privacy notice.

## Bridge contract

| Call | Result | Notes |
|---|---|---|
| `authorize({ developerToken })` | `{ authorized, error? }` | Shows the system "Allow Ratify Music to access Apple Music?" prompt the first time. The developer token is not needed natively. |
| `unauthorize()` | `{}` | iOS can't take back an app's permission, so "Disconnect" is remembered and `isAuthorized` reports false until the member connects again (no second prompt). |
| `isAuthorized()` | `{ authorized }` | |
| `play({ queue })` | `{ ok, error? }` | `queue` is `{ songs: [id, …] }` or `{ album: id }`, using Apple Music catalog ids. Needs an active Apple Music subscription. |
| `pause()`, `resume()` | `{}` | |
| `stop()` | `{}` | Pauses and keeps the position, like the web player. The site's song button toggles `stop()` / `resume()` on the same track, and MusicKitContext's web `stop()` calls `pause()`. |
| `addListener('playbackEvent', cb)` | Promise of a handle | Events are `{ state: 'playing' \| 'paused' \| 'ended' \| 'stopped' }` on each change, and `{ progress: 0…1 }` every 0.5 s while playing. |

Errors are written for members to read, for example: Apple Music access is off
in Settings, no subscription, or "open the Music app once and accept Apple
Music's privacy notice".

Playback stops when the page is replaced (reload, sign-in, leaving for
Stripe), the same as closing a browser tab ends MusicKit JS. Otherwise a song
would keep playing with no control on the new page.

## Stripe

Checkout and the billing portal open in **Safari**, where Apple Pay works,
exactly as before. The site sends the page to Stripe
(`window.location.href = url`), and the app hands any address outside the
site to Safari. When the member comes back to the app, the page they left is
reloaded, so its "Redirecting…" button resets and the new balance or plan
shows. Don't add Stripe hosts to `allowNavigation` in `capacitor.config.ts`,
because that would keep Checkout inside the app.

## Building

Requirements: Node 20+, Xcode 26.

```bash
npm install
npx cap sync ios
npx cap open ios
```

In Xcode, set the version and build number, then go to Product, then Archive,
then Distribute App, then App Store Connect. The build number must be higher
than every build already uploaded for the app, including Base44's.

Other scripts:

- `npm run assets` rebuilds the icon and launch screen from
  `assets-source/ratify-black-base44.png`, the site's own icon.

### Debug-only test hooks

Debug builds accept two launch arguments. Neither is compiled into Release or
TestFlight builds.

- `-NativeMusicKitSelfTest YES` calls every bridge method from inside the page
  and logs the results.
- `-ShellDebugJS "<script>"` runs a script once in the first page.

Example run against a simulator:

```bash
xcrun simctl launch --console-pty <device> com.base69900c52dad19ccce6c947de.app -NativeMusicKitSelfTest YES
```

## Files

- `capacitor.config.ts` holds the site URL, the hosts allowed inside the app,
  and the colours.
- `ios/App/App/NativeMusicKitPlugin.swift` is the MusicKit plugin.
- `ios/App/App/Base44AuthPlugin.swift` is social sign-in and universal links.
- `ios/App/App/ShellViewController.swift` is the WebView container, launch
  cover, progress bar and Stripe return.
- `www/shell-bridge.js` is injected into the site. It makes `addListener`
  return a Promise, as the site's bridge expects.
- `www/index.html` is the offline screen.
