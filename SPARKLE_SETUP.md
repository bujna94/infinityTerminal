# Sparkle setup

Sparkle is wired into the app (SwiftPM dependency, `Updater.swift`,
"Check for Updates…" menu item, framework embedded + signed by `build-app.sh`,
Info.plist keys with the feed URL). What's still missing is the one-time
infrastructure to actually serve and verify updates: an EdDSA key pair, the
`appcast.xml` hosted on the website, and the build pipeline signing each new
DMG.

Until these steps are completed, the app launches normally but
"Check for Updates…" will fail signature verification and never install
anything.

## 1. Generate the EdDSA key pair (one-time)

Sparkle ships a `generate_keys` tool. Easiest way to get it:

```sh
# clone Sparkle and build the tools — produces bin/generate_keys + bin/sign_update
git clone --depth 1 https://github.com/sparkle-project/Sparkle /tmp/sparkle
cd /tmp/sparkle && ./bin/generate_keys
```

`generate_keys` prints the **public key** (a base64 string) and stores the
**private key** in your macOS login keychain under the account `ed25519`.
Back the private key up somewhere safe (1Password, Bitwarden) — losing it
means future versions of the app can't deliver auto-updates that current
installs will trust.

Take the printed public key string and:

- Set it as the env var `SPARKLE_PUBLIC_ED_KEY` before running
  `./build-app.sh` locally (or hardcode it into `build-app.sh`'s Info.plist
  block — replace the `${SPARKLE_PUBLIC_ED_KEY:-}` line).
- Add it as a GitHub Actions secret named `SPARKLE_PUBLIC_ED_KEY` so the CI
  release workflow can inject it.
- Export the private key (`security find-generic-password -ws ed25519 -a ed25519`)
  base64-encode it, and add it as a GitHub Actions secret named
  `SPARKLE_PRIVATE_ED_KEY` so CI can run `sign_update`.

## 2. Host the appcast

Add `appcast.xml` to the `infinityTerminalWeb` repo at the repo root. Initial
file (with no entries — Sparkle treats this as "no updates available"):

```xml
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Infinity Terminal Updates</title>
    <link>https://infinityterminal.com/appcast.xml</link>
    <description>Most recent updates to Infinity Terminal</description>
    <language>en</language>
  </channel>
</rss>
```

Once deployed, the file is at https://infinityterminal.com/appcast.xml — which
matches the `SUFeedURL` already in the Info.plist.

## 3. Update the release pipeline to sign + publish each update

Two new jobs in `.github/workflows/release.yml` after the `Create GitHub Release`
step:

```yaml
- name: Sign DMG with EdDSA for Sparkle
  env:
    SPARKLE_PRIVATE_ED_KEY: ${{ secrets.SPARKLE_PRIVATE_ED_KEY }}
  run: |
    set -euo pipefail
    # Restore the private key into a temporary keychain
    echo "$SPARKLE_PRIVATE_ED_KEY" | base64 --decode > "$RUNNER_TEMP/ed25519.key"
    SIG=$(/path/to/sign_update -f "$RUNNER_TEMP/ed25519.key" .build/*.dmg | awk -F\" '/sparkle:edSignature/ {print $2}')
    LEN=$(stat -f%z .build/*.dmg)
    echo "EDSIG=$SIG" >> "$GITHUB_ENV"
    echo "SIZE=$LEN" >> "$GITHUB_ENV"

- name: Append entry to appcast.xml in web repo
  env:
    GH_TOKEN: ${{ secrets.WEB_REPO_PAT }}
  run: |
    # clone web repo, prepend a new <item> with version, edSignature, length, pubDate
    # commit + push
```

Take this as a sketch; the actual sign_update binary path depends on whether
you vendor Sparkle's tools (recommended: `swift run -c release sparkle-tools-sign-update`
once Sparkle exposes them via SPM, currently they're in the binary release
distribution).

## 4. First post-Sparkle release

The first DMG published with a real `SUPublicEDKey` and a corresponding
appcast entry becomes the baseline. Existing installs (currently v1.0.11,
which has no Sparkle) won't auto-update — users have to install the first
Sparkle-enabled version manually. After that, all future releases flow
through the auto-updater.
