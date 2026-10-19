# Contributing to Headroom

Use [Issues](https://github.com/jkudish/headroom/issues) for bugs and feature requests. Include your macOS version, Headroom commit, provider, expected behavior, and a safe reproduction. Remove emails, account IDs, credentials, cookies, and private billing data from screenshots and logs. Send security reports through [SECURITY.md](SECURITY.md).

For a substantial change, describe the problem and proposed scope in an issue before building it.

## Build locally

Use macOS 14+ and Xcode 26+ with Swift 6. Select the full Xcode installation; Command Line Tools alone don't include the Icon Composer tooling used by the bundle script.

```sh
git clone https://github.com/jkudish/headroom.git
cd headroom
swift test
HEADROOM_SIGNING_IDENTITY=- bash scripts/build-app.sh
open -n .build/Headroom.app --args --demo
```

The package has no external Swift package dependencies. `swift build` builds the executable; `scripts/build-app.sh` also packages resources, compiles the icon, creates `.build/Headroom.app`, and verifies its signature. It doesn't install, notarize, or publish anything.

`HEADROOM_SIGNING_IDENTITY=-` explicitly selects ad-hoc signing for local use. Set it to your own codesigning identity for a certificate-signed build. With the variable unset, the script retains the maintainer's certificate and fails if it is unavailable. It never silently changes identity. Neither path produces a notarized release. Changing signatures or app locations can change Keychain trust; don't overwrite your daily-use app while testing.

## Check a change

```sh
swift test --filter MonitorTests
swift test
HEADROOM_SIGNING_IDENTITY=- bash scripts/build-app.sh
git diff --check
```

Tests use synthetic credentials, temporary account stores, and injected provider responses. Keep them that way. Don't read real Keychain entries, import local credentials, sign in, or redeem reset credits as part of an automated test.

Use `--demo` to inspect the production UI with fixtures. Quit the demo instance when finished. For appearance changes, inspect light and dark mode, the compact menu, a single account, and multiple accounts in the settings window. Check missing readings and errors when relevant. Demo rendering does not verify provider authentication, notification delivery, Keychain permissions, or assistive technology.

There is no repository-specific formatter or hosted CI workflow. Follow nearby Swift style. Run the checks above against the commit you submit; don't describe an untested provider as verified.

## Send a pull request

Keep the change focused. Explain the user-visible behavior, checks run, and anything still unverified. Include synthetic screenshots for UI changes. Add a regression test when a plausible bug would otherwise go unnoticed.

Provider changes must preserve account isolation, safe errors, units, and missing-value handling. Keep the [provider table](docs/providers.md) aligned with `Providers.swift` and its clients. Never convert an unavailable reading into zero or guess a recurring quota window.

The executable name, bundle ID, storage root, and Keychain service names predate the Headroom name. Don't rename them as cosmetic cleanup; they identify existing accounts and credentials. See [Security](SECURITY.md) and the relevant storage/auth code before changing persistence.

Use fixtures rather than personal data for README images. Record the source of new provider artwork in [Third-party notices](THIRD_PARTY_NOTICES.md).
