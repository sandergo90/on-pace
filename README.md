<p align="center">
  <img src="UsageNotch/Assets.xcassets/AppIcon.appiconset/UsageNotch-256.png" width="120" alt="On pace. Trail icon">
</p>

<h1 align="center">On pace.</h1>

<p align="center">Claude Code and Codex usage at a glance in your Mac's notch.</p>

<p align="center"><a href="https://github.com/sandergo90/on-pace/releases">Download for macOS</a> · macOS 14+</p>

## See it in action

<p align="center">
  <img src="docs/images/on-pace-0.1.2-notch.png" width="820" alt="Collapsed notch showing Claude at 68% of its session limit and Codex at 7% of its weekly limit">
</p>

Hover over the notch to see reset times, recent activity, and usage history.

<p align="center">
  <img src="docs/images/on-pace-0.1.2-detail.png" width="820" alt="Expanded panel showing a Claude session ring and a Codex weekly limit ring, alongside activity charts and seven-day history">
</p>

The screenshots show sample usage. The Codex ring shows the weekly limit when a five-hour limit is unavailable.

## Install

1. Open [GitHub Releases](https://github.com/sandergo90/on-pace/releases).
2. Download the macOS ZIP and unzip it.
3. Move **On pace.** to Applications and open it.

Use macOS 14 or later on a Mac with Apple silicon or an Intel processor. Install and sign in to the command-line tool for each provider you want to track. [Claude Code setup](https://code.claude.com/docs/en/quickstart) · [Codex setup](https://developers.openai.com/codex/cli)

## Use the notch

- The notch shows the reported five-hour limit, or the weekly limit when the five-hour limit is unavailable.
- Hover for the breakdown. Click the notch or use the pin to keep it open.
- Choose **7 days** or **30 days** to compare activity with the preceding period. The app remembers your choice.
- Use the gear menu to open **Settings…**, **About On pace.**, **Check for Updates…**, or quit.
- On pace. checks for stable releases at launch and about once a day while running. A dot on the gear shows when an update is available.
- Open **Update Available** and choose **Install Update**. On pace. verifies the download and lets you install it and relaunch.
- On a display without a camera notch, a compact notch shape sits at the top edge, within the menu bar's height.
- The small `5h` and `wk` labels identify the period beside each percentage. The panel shows the same limit in its ring.
- In **Settings > Providers**, choose which providers appear in the notch, panel, and history. At least one stays on.
- In **Settings > General > Display**, choose the primary display or a specific monitor. The app remembers your choice and uses the primary display when that monitor is disconnected.

## Usage data

On pace. reads session logs on your Mac for tokens, cache hits, sessions, and activity. It requests quota readings through your installed CLI tools and their existing sign-ins. The app keeps no separate copy of your credentials. It refreshes quota readings every minute and dims the last reading after five minutes without a fresh one.

API values are estimates in euros based on the published rates and exchange rate in `StandardTokenRates.swift`. If the app can price only some of the logged tokens, it labels the estimate as partial.

The Claude Code quota reader uses the CLI's internal `get_usage` command. A CLI update can change its behavior. Codex quota windows depend on what your account reports.

## Build from source

Open `UsageNotch.xcodeproj` in Xcode and choose **Product > Run**. You can also build from Terminal.

```sh
xcodebuild -project UsageNotch.xcodeproj -scheme UsageNotch -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode build
open ".build/xcode/Build/Products/Debug/On pace..app"
```

If you edit `project.yml`, run `xcodegen generate` to refresh the Xcode project.

## Publish a release

Update the app version and increase the build number in `project.yml` in a pull request. Run `xcodegen generate` to update `UsageNotch/Info.plist`. After merging the pull request, tag the merged commit with the matching version and push the tag. For example, use `v0.1.5` for app version `0.1.5`.

```sh
git switch main
git pull --ff-only
git tag -a v0.1.5 -m 'On pace. 0.1.5'
git push origin v0.1.5
```

GitHub Actions builds, signs, and notarizes the universal app. It publishes the ZIP and the signed Sparkle update feed together as a stable release. If a run fails because of missing credentials or a temporary service error, fix the issue and rerun it from the **Actions** tab.

Set these secrets in the [macos-release environment](https://github.com/sandergo90/on-pace/settings/environments) before pushing the first automated release tag.

| Secret | Value |
| --- | --- |
| `MACOS_SIGNING_CERTIFICATE` | Base64 of a Developer ID Application `.p12` export that includes the private key |
| `MACOS_SIGNING_CERTIFICATE_PASSWORD` | Password for the `.p12` export |
| `APPLE_NOTARY_KEY` | Contents of the App Store Connect team API key file (`.p8`) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Sparkle private key exported from the `be.kodeus.UsageNotch` Keychain account with `generate_keys` |

Keep the Sparkle key in Keychain so it can sign updates for copies already installed. [Sparkle signing guide](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures)

[Create a Developer ID certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) · [Create an App Store Connect team API key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)

## License

The source is available under the [MIT License](LICENSE). On pace. is an independent Kodeus app. The notch design was inspired by [Agent HUD](https://github.com/jazzenchen/agent-hud-open).
