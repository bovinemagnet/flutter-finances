# Release packaging and signing

This folder holds the packaging scripts used by the GitHub Actions workflows
in `.github/workflows`, and documents how signed releases are produced,
staged and rolled back (PRD section 15, "Platform support and distribution",
and the release checks in section 16).

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | push to `main`, pull requests | `dart analyze` and `dart test` for `finance_core` and `finance_store`; `flutter analyze` and `flutter test` for the app; `./gradlew build` for the server on Java 25; the end-to-end suite (`tool/e2e/run.sh` with Docker) |
| `build.yml` | push to `main`, pull requests | Unsigned builds, each on its own OS: Android APK and AAB, Linux bundle plus `.tar.gz`/`.deb` (Ubuntu 24.04), Windows, macOS, iOS with `--no-codesign` |
| `release.yml` | tag `vX.Y.Z` or `vX.Y.Z-suffix` | Signed Android, signed iOS IPA (with the share extension), signed and notarised macOS, signed Windows MSIX, Linux packages, dependency inventory, checksums, build provenance attestation and a **draft** GitHub release |

`gradle25w` is a local wrapper that selects Java 25 before calling `./gradlew`;
CI installs Java 25 with `actions/setup-java` and calls `./gradlew` directly.

## Secrets

Add these as repository (or `release` environment) secrets. Pull requests and
`build.yml` never read them. `release.yml` **fails closed**: its preflight job
stops the release if any of them is missing, each signing job checks its own
secrets again, and the Android build refuses to fall back to the debug key
(`FINANCE_REQUIRE_RELEASE_SIGNING=true`).

| Secret | Platform | Contents |
| --- | --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Android | Upload keystore (`.jks`), base64 encoded: `base64 -w0 upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Android | Keystore password |
| `ANDROID_KEY_ALIAS` | Android | Key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | Android | Key password |
| `MACOS_CERTIFICATE_P12_BASE64` | macOS | "Developer ID Application" certificate and private key exported as `.p12`, base64 encoded |
| `MACOS_CERTIFICATE_PASSWORD` | macOS | Password of the `.p12` |
| `MACOS_SIGNING_IDENTITY` | macOS | Identity name, for example `Developer ID Application: Paul Snow (TEAMID1234)` |
| `APPSTORE_API_KEY_P8_BASE64` | macOS | App Store Connect API key (`AuthKey_XXXX.p8`, Developer role), base64 encoded, used by `notarytool` |
| `APPSTORE_API_KEY_ID` | macOS | Key ID of that API key |
| `APPSTORE_API_ISSUER_ID` | macOS | Issuer ID of the App Store Connect team |
| `WINDOWS_CERTIFICATE_PFX_BASE64` | Windows | Code signing certificate and key as `.pfx`, base64 encoded; its subject becomes the MSIX publisher |
| `WINDOWS_CERTIFICATE_PASSWORD` | Windows | Password of the `.pfx` |
| `IOS_DISTRIBUTION_P12_BASE64` | iOS | "Apple Distribution" certificate and private key exported as `.p12`, base64 encoded |
| `IOS_DISTRIBUTION_P12_PASSWORD` | iOS | Password of the `.p12` |
| `IOS_APP_PROFILE_BASE64` | iOS | App Store provisioning profile for `com.paulsnow.finance.app` (App Group `group.com.paulsnow.finance.app` enabled), base64 encoded |
| `IOS_SHARE_EXTENSION_PROFILE_BASE64` | iOS | App Store provisioning profile for `com.paulsnow.finance.app.ShareExtension` with the same App Group, base64 encoded |
| `IOS_TEAM_ID` | iOS | Apple Developer team ID |

Signing material is written only to the runner's temporary directory and is
removed in an `always()` step. Keystores, certificates and `key.properties`
are ignored by git (`.gitignore`) and must never be committed.

### Android

`apps/finance_app/android/app/build.gradle.kts` reads
`apps/finance_app/android/key.properties` when it exists:

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

Without that file, local release builds are signed with the debug key so that
`flutter run --release` keeps working. The workflow checks the APK with
`apksigner verify --print-certs` and the App Bundle with `jarsigner`, and
fails if either carries the debug certificate. Google Play App Signing holds
the distribution key; the secret is the upload key only.

### macOS

The app is built with `flutter build macos`, re-signed inside out with the
Developer ID identity and the hardened runtime
(`macos/Runner/Release.entitlements`), submitted with
`xcrun notarytool submit --wait`, stapled with `xcrun stapler staple`, and
checked with `spctl --assess`. A notarisation status other than `Accepted`
prints the notary log and fails the job. Build and test on macOS only.

### Windows

`dart run msix:create` packages the `flutter build windows` output using
`msix_config` in `apps/finance_app/pubspec.yaml`, signs it with the `.pfx`
(the certificate, password and four-part version are passed on the command
line), and `signtool verify /pa` checks the result. The certificate must
chain to a trusted root for the verification, and for installation, to pass.

### Linux

`tool/packaging/linux/build-deb.sh` turns the `flutter build linux --release`
bundle into:

- `finance-app-<version>-linux-<arch>.tar.gz`: the bundle plus `share/` with
  the desktop file, icons and AppStream metainfo. Unpack anywhere and run
  `./finance_app`; copy `share/*` into `~/.local/share` for menu integration.
- `finance-app_<version>_<arch>.deb`: the bundle in `/opt/finance-app`, a
  `/usr/bin/finance-app` launcher, `com.paulsnow.finance.app.desktop`, icons
  and `com.paulsnow.finance.app.metainfo.xml`. It depends on GTK 3,
  libsecret (the database key lives in the Secret Service), WebKitGTK 4.1 and
  libsoup 3, and recommends a Secret Service provider.

```sh
cd apps/finance_app && flutter build linux --release && cd ../..
tool/packaging/linux/build-deb.sh                 # tarball, plus .deb when dpkg-deb exists
tool/packaging/linux/build-deb.sh --tarball-only  # tarball only
tool/packaging/linux/build-deb.sh --require-deb   # fail if the .deb cannot be built (CI)
```

Archives are reproducible for a given commit (sorted entries, fixed owner and
`SOURCE_DATE_EPOCH` timestamps). The desktop file and metainfo are validated
with `desktop-file-validate` and `appstreamcli validate` when installed. On
machines without `dpkg-deb` the script builds the tarball and skips the
`.deb`; CI always builds the `.deb` on Ubuntu.

**Tested distributions:** Ubuntu 24.04 LTS on x64 is the baseline; CI builds
the package there and installs it with `apt-get`. Ubuntu 22.04 should work
(the dependency list allows its package names) but is best effort, as are
other distributions using the tarball. ARM64 is not yet validated against the
chosen plugins and must not be advertised until it is.

The package is not signed itself; its integrity comes from `SHA256SUMS` and
the provenance attestation on the GitHub release (below).

### iOS

`build.yml` builds iOS without code signing. Before building, it runs
`apps/finance_app/ios/tool/add_share_extension.rb` (needs the `xcodeproj`
gem), which adds the `ShareExtension` target used by `receive_sharing_intent`:
bundle id `com.paulsnow.finance.app.ShareExtension`, App Group
`group.com.paulsnow.finance.app` on both Runner and the extension, the
`receive-sharing-intent` Swift package product, and the
"Embed Foundation Extensions" phase ahead of "Thin Binary". The script is
idempotent; a developer with Xcode can run it once and commit the updated
`project.pbxproj`.

`release.yml` runs the same script, installs the distribution certificate in
a temporary keychain and both provisioning profiles, switches the Release
configuration of Runner and ShareExtension to manual signing (in the runner's
checkout only) and builds an App Store IPA with `flutter build ipa`. It then
checks that the extension is embedded and that the app is signed with
"Apple Distribution", and attaches the IPA to the draft release. Uploading it
to TestFlight stays a manual step (Transporter or `xcrun altool`), like the
other store roll-outs below.

## Release provenance

Every tagged release records:

- `inventory-flutter-pub-deps.json` (`flutter pub deps --json`) and
  `inventory-pubspec.lock` for the client;
- `inventory-server-*-runtime.txt` (Gradle `dependencies` for the runtime
  classpath) for the server, and `inventory-android-release-runtime.txt` for
  the Android app;
- `inventory-flutter-sdk.json` and `inventory-java.txt` for the toolchains;
- `SHA256SUMS` over every artefact, and a GitHub build provenance attestation
  (`actions/attest-build-provenance`) for each file, verifiable with
  `gh attestation verify <file> --repo bovinemagnet/flutter-finances`.

## Cutting a release

1. Make sure `CI` and `Build` are green on `main`, and the release checks in
   PRD section 16 are met (P0 acceptance scenarios, backup and restore drill,
   accessibility review).
2. Tag and push: `git tag -s v1.2.3 -m "Finance 1.2.3" && git push origin v1.2.3`.
   The tag supplies the version; the workflow run number supplies the build
   number (Android `versionCode`, `CFBundleVersion`).
3. Wait for `Release` to finish. It creates a **draft** release with all
   artefacts, `SHA256SUMS` and generated notes.
4. Install and smoke test each artefact on its own OS (Apple Silicon macOS,
   Windows x64, Ubuntu 24.04, a current and previous Android release).
5. Publish the draft, then start the staged roll-outs below.

## Staged updates

- **Google Play:** upload the `.aab` to the internal track first, then promote
  to production as a staged roll-out (for example 5 %, 20 %, 50 %, 100 %),
  watching crash rate, ANRs and sync error metrics between steps.
- **App Store (iOS):** TestFlight first, then phased release for automatic
  updates (seven-day ramp), which can be paused.
- **macOS and Windows:** publish the notarised zip and the MSIX on the GitHub
  release; announce to a small group before linking it more widely.
- **Linux:** publish the `.deb` and tarball on the GitHub release.
- **Server:** clients must tolerate older and newer servers (NFR 12); deploy
  server changes that clients depend on before the client release, and keep
  changes additive until every supported client understands them.

## Rollback

- **Stop the roll-out first.** Halt the Play staged roll-out, pause the App
  Store phased release, and mark the GitHub release as a pre-release (or
  unpublish it) so the download links stop pointing at it.
- **Ship forward rather than downgrade.** Stores do not allow lower version
  codes, and local databases may already have been migrated (NFR 11). Fix
  forward with a new tag; for a quick revert, tag the previous good commit
  with a higher patch version (for example `v1.2.4` built from the `v1.2.2`
  commit), which gets a new build number automatically.
- **Desktop and Linux users** can reinstall the previous artefact from its
  GitHub release, but only if no schema migration has run; release notes must
  say when a release contains a migration, and destructive migrations need a
  recovery plan before release.
- **Server:** roll back the deployment to the previous image; Liquibase
  changes must be additive so the previous server still runs against the
  migrated schema.
- **Signing keys:** if a signing secret leaks, revoke it (Play upload key
  reset, Apple Developer ID revocation, Windows certificate revocation),
  replace the secret and re-release; attestation and checksums identify which
  artefacts were signed with the old key.
