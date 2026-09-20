# Releasing Blink

Releases are cut by pushing a `vX.Y.Z` tag. `.github/workflows/release.yml`
runs the unit tests, then builds, signs, notarizes, staples, packages, and
publishes a DMG, a zip, and a signed Sparkle `appcast.xml` to the GitHub
Release for that tag.

> The repository is assumed to be `inxilpro/blink`. The workflows do not
> hard-code it (they publish to whatever repository they run in), but
> `SUFeedURL` in `Blink/Info.plist` does — it is the one place the app learns
> where updates live. The release workflow refuses to publish when `SUFeedURL`
> doesn't point at the repository it runs in.

Blink is distributed outside the Mac App Store with Developer ID signing and
notarization. The App Sandbox is off (it blocks the CoreMediaIO device-state
observation the app depends on); the hardened runtime is on, and the app needs
no entitlements.

## Runner image and Xcode

Both workflows run on the GA `macos-26` image using whatever Xcode that image
makes default. The project is `objectVersion = 77` and targets macOS 15.7, so
any Xcode 26.x builds it — unlike Short Circuit, Blink does not need the
`xcode-27` preview image. No `/Applications/Xcode_*.app` path is pinned,
because a pinned path the image later drops fails the whole workflow; each run
logs `xcodebuild -version` so the actual version is always in the log. If a
specific Xcode ever becomes necessary, add an `XCODE_APP` env var and a
`sudo xcode-select -s` step to **both** workflows together.
Current images: <https://github.com/actions/runner-images#available-images>.

## Secrets

All eight are already set on this repository. They are the same values the
other apps use; none is specific to Blink.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any random string; protects the throwaway CI keychain only |
| `APPLE_TEAM_ID` | `657AK7D2D9` |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_PRIVATE_KEY` | contents of the `AuthKey_*.p8` file |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (`generate_keys -x`) |

`GITHUB_TOKEN` is provided automatically; the workflow's
`permissions: contents: write` lets it create the release. No repository
variables are needed.

To recreate any of them, `Documentation/RELEASING.md` in the Short Circuit
repository has the full step-by-step for the certificate and the API key.

## The Sparkle key

Sparkle signs each update archive with an EdDSA key, and the app verifies it
with the public key in `Blink/Info.plist` (`SUPublicEDKey`).

**Blink reuses the shared key**, the one under the default `ed25519` keychain
account that Chronicle and Short Circuit also use. `SUPublicEDKey` is that
key's public half, so the existing `SPARKLE_PRIVATE_KEY` value works here
unchanged.

Confirm the committed public key matches the private key CI will use:

```sh
/path/to/Sparkle-2.10.0/bin/generate_keys -p
# must print: bA1sl1HrvwpXicvAwazlXX2ntAhNY+EnDGZWLl26il4=
```

The trade-off is that one leaked private key could sign updates for every app
sharing it. To give Blink its own key, do it **before the first release** —
once copies are installed, they only accept updates signed with the key they
shipped with:

```sh
./bin/generate_keys --account blink        # prints the public key → SUPublicEDKey
./bin/generate_keys --account blink -x blink-sparkle-key.txt
gh secret set SPARKLE_PRIVATE_KEY < blink-sparkle-key.txt
```

Keep a secure backup of the private key and delete the file. Losing it strands
every installed copy on its current version. To change keys after releases have
shipped, publish one transition release carrying the new `SUPublicEDKey` but
still signed with the old private key; installed copies accept it, and every
release after it uses the new key.

## How updates are served

`SUFeedURL` points at
`https://github.com/inxilpro/blink/releases/latest/download/appcast.xml`.
GitHub's `releases/latest/download/` always resolves to the newest published
release's asset, so the appcast generated for a release only needs to describe
that one version — there is no accumulating feed file and nothing to host.

Sparkle only starts in Release builds (`Updates/UpdaterController.swift`); a
Debug build would otherwise offer to replace itself with the published
release, and the unit tests must never touch the network. The **Check for
Updates…** item is hidden from the status menu whenever the updater isn't
running, which is why it doesn't appear in Debug builds.

### Updating Sparkle

Bump the package in Xcode, then update `SPARKLE_VERSION` in `release.yml` to
the newly resolved version. The workflow's first step compares the two and
fails the release if they disagree, because a `generate_appcast` from a
different version can produce an appcast the shipped app can't use.

## Cutting a release

1. Update `MARKETING_VERSION` if you want the in-project value to match; the
   workflow overrides both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
   with the tag, so the tag is the source of truth.
2. Commit, push to `main`, and wait for CI to go green.
3. Tag and push:

   ```sh
   git tag v1.2.0
   git push origin v1.2.0
   ```

A release takes roughly five minutes, most of it notarization (the app and the
DMG are notarized separately).

## Verifying a release

```sh
gh run list --workflow release.yml --limit 1
gh release view v1.2.0
```

Then, on a Mac that has never run the build:

```sh
spctl -a -t exec -vv /Applications/Blink.app     # accepted, source=Notarized Developer ID
codesign --verify --deep --strict -vv /Applications/Blink.app
xcrun stapler validate /Applications/Blink.app
```

The workflow already asserts all of this before publishing: signatures and
secure timestamps on every nested Sparkle binary, no `get-task-allow`, a
Gatekeeper assessment, a bundle version matching the tag, and an
`sparkle:edSignature` present in the generated appcast.

### The update path, end to end

The only way to be sure updates work is to install an older release and let it
update itself. Install the previous version from its DMG, launch it, and use
**Check for Updates…** in the status menu. A failure here after a key change
is silent from the publisher's side: the release looks perfect and installed
copies simply never update.
