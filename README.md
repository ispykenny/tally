# Tally

A native macOS menu bar app (SwiftUI + Liquid Glass) that shows open pull requests
from GitHub repositories you subscribe to, and notifies you when a new PR opens.

## Features

- Lives entirely in the menu bar (`LSUIElement`) with a Liquid Glass UI (macOS 26)
- Sign in with a GitHub personal access token — stored securely in the Keychain
- Search GitHub repositories by name (or exact `owner/repo`) and subscribe with one click
- Open-PR list grouped by repo; the menu bar icon shows the total PR count
- Polls every 60 seconds; posts a macOS notification when a new PR opens
- Click a PR row (or a notification) to open the PR on github.com
- Over-the-air updates via Sparkle

## Build & run

Requires Xcode 26 / macOS 26.

```sh
./build.sh                        # builds build/Tally.app
open build/Tally.app              # run it
cp -R build/Tally.app /Applications/     # optional: install
```

## Sign in

1. Click the menu bar icon → “Create a token on GitHub”
   (or visit https://github.com/settings/tokens/new?scopes=repo)
2. Generate a classic token with the **repo** scope (a fine-grained token with
   read access to pull requests also works)
3. Paste it into Tally and press **Sign In**

Then open the gear menu → **Manage Repositories…** and search for repos to
subscribe — free text ("react") or an exact `owner/repo`.

## Releasing

```sh
./release.sh 1.1
```

That bumps the version in Info.plist (build number = commit count), commits,
tags `v1.1`, and pushes. The `release.yml` GitHub Actions workflow then
builds a universal binary, signs, notarizes, generates the Sparkle
appcast, and publishes a GitHub Release with the dmg + zip attached.
Users download from `https://github.com/ispykenny/tally/releases/latest`,
and running apps pick the release up over the air via Sparkle.

### Repo secrets the workflow needs

| Secret | What it is |
| --- | --- |
| `MACOS_CERT_P12` | base64 of a **Developer ID Application** cert + key (.p12) |
| `MACOS_CERT_PASSWORD` | the .p12's password |
| `NOTARY_KEY` | base64 of an App Store Connect **API key** (.p8) |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER` | that key's issuer UUID |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (`generate_keys -x -`) |

All are optional but degrade: no cert → ad-hoc build Gatekeeper blocks on
other Macs; no notary key → signed but un-notarized; no Sparkle key → no
appcast, so no over-the-air update for that release.

### How the update feed works

The app's `SUFeedURL` points at
`…/releases/latest/download/appcast.xml`. Each release publishes an
appcast describing itself, signed with the Sparkle EdDSA key
(`SUPublicEDKey` in Info.plist is the matching public key). "Latest"
always serves the newest release's appcast, so older apps see it and
offer the update.

### Local packaging (without CI)

`./dist.sh` does the same build/sign/package locally — see the comments
at the top of the script for signing and notarization options.

## Notes

- The first fetch for a repo seeds silently, so subscribing doesn't blast
  notifications for PRs that were already open — you're only notified about
  PRs opened afterwards.
- Notifications require running the assembled `Tally.app` bundle
  (not `swift run`) and accepting the notification permission prompt.
- Subscriptions live in `UserDefaults` (`com.ispykenny.tally`); the token
  lives in the login Keychain under the same service name.
