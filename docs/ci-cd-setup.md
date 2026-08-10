# CI/CD: Building & Publishing iPadDx via GitHub Actions

How to set up and use the GitHub Actions workflow to build, archive, and publish iPadDx to App Store Connect / TestFlight.

---

## Overview

The workflow (`.github/workflows/build-and-publish.yml`) has three modes:

| Trigger | What happens |
|---|---|
| Push to `main` or PR | **CI build only** — compiles all bridges without signing to verify nothing is broken |
| Push a tag like `v1.0.0` | **Full pipeline** — build bridges + archive + sign + export IPA + upload to App Store Connect |
| Manual dispatch (Actions tab) | **Choose** whether to just build or also upload to TestFlight |

### What the workflow builds

The full pipeline builds 4 bridge runtimes before compiling the main app:

1. **Flutter** — `flutter build ios-framework` produces `Flutter.xcframework` + `App.xcframework`
2. **React Native** — `npm ci` + `npx react-native bundle` (JS bundle) + `xcodebuild` (static lib) + `libtool` (merge) + copy `hermes.xcframework`
3. **Capacitor** — `npm ci` to get `@capacitor/core` + `@capacitor/ios`
4. **Cordova** — copies real `cordova.js` from Capacitor's node_modules + `index.html` into bundle resources

Then: `pod install` (root) + `xcodebuild archive` + `xcodebuild -exportArchive` + upload.

---

## One-Time Setup: GitHub Secrets

Go to your repo > **Settings** > **Secrets and variables** > **Actions** > **New repository secret** and add these 7 secrets:

### 1. `APPLE_CERTIFICATE_BASE64`

Your **Apple Distribution** certificate as a `.p12` file, base64-encoded.

```bash
# In Keychain Access, export your "Apple Distribution: Christian Lyons (Z86ZAY4JRW)"
# certificate + private key as a .p12 file, then:
base64 -i Certificates.p12 | pbcopy
# Paste as the secret value
```

### 2. `APPLE_CERTIFICATE_PASSWORD`

The password you set when exporting the `.p12` file.

### 3. `APPLE_PROVISIONING_PROFILE_BASE64`

Your **App Store** provisioning profile, base64-encoded.

```bash
# Download from https://developer.apple.com/account/resources/profiles/list
# or find in ~/Library/MobileDevice/Provisioning Profiles/
base64 -i "YourProfile.mobileprovision" | pbcopy
```

Make sure the profile:
- Is type **App Store**
- Matches bundle ID `com.christianlyons.ipadconnection`
- Includes all entitlements (multicast, wifi-info, sustained-execution, increased-memory-limit)
- Is linked to the same distribution certificate

### 4. `KEYCHAIN_PASSWORD`

Any random string. Used to create a temporary keychain on the CI runner.

```bash
openssl rand -base64 32 | pbcopy
```

### 5. `APPSTORE_CONNECT_API_KEY_ID`

The **Key ID** of your App Store Connect API key.

### 6. `APPSTORE_CONNECT_ISSUER_ID`

The **Issuer ID** shown at the top of the API keys page.

### 7. `APPSTORE_CONNECT_API_KEY_BASE64`

The `.p8` API key file, base64-encoded.

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

#### How to create an App Store Connect API key:

1. Go to [App Store Connect > Users and Access > Integrations > App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
2. Click **Generate API Key**
3. Name: `GitHub Actions CI`
4. Access: **App Manager** (minimum needed to upload builds)
5. Download the `.p8` file — **you can only download it once!**
6. Note the **Key ID** and **Issuer ID** shown on the page

---

## Usage

### Automatic: Tag a Release

```bash
# Bump version in Xcode first, then:
git add -A
git commit -m "Release v1.0.0"
git tag v1.0.0
git push origin main --tags
```

This triggers the full pipeline: build bridges > archive > sign > upload to TestFlight.

### Manual: Dispatch from GitHub

1. Go to **Actions** tab in your repo
2. Select **Build & Publish iPadDx** workflow
3. Click **Run workflow**
4. Set "Upload to App Store Connect?" to `true`
5. Click **Run workflow**

### CI Only: Push or PR to main

Every push or PR to `main` runs a build-only check (no signing, no upload). This verifies that all bridge frameworks build and the main app compiles.

---

## What Happens After Upload

1. Build appears in **App Store Connect > TestFlight** within ~5-30 minutes
2. It goes through **Processing** automatically
3. Internal testers (up to 25) can test immediately without review
4. Add external testers if needed (requires Beta App Review, ~24h)
5. When ready, select the build under **App Store** tab and submit for review

---

## Build Pipeline Detail

```
Checkout
  |
  v
Select Xcode 16.x (latest on runner)
  |
  +-- Build Flutter frameworks (flutter build ios-framework)
  |     -> Frameworks/Flutter.xcframework, App.xcframework
  |
  +-- Build React Native bridge
  |     +-- npm ci (install react-native + hermes)
  |     +-- npx react-native bundle (-> iPadDx/Resources/main.jsbundle)
  |     +-- pod install (RN bridge pods)
  |     +-- xcodebuild (-> static libs)
  |     +-- libtool merge (-> Frameworks/ReactNative/libReactNative.a)
  |     +-- copy hermes.xcframework (-> Frameworks/hermes.xcframework)
  |
  +-- Install Capacitor npm packages (npm ci)
  +-- Copy Cordova JS assets (cordova.js + index.html -> cordova_www/)
  |
  v
pod install (root — Capacitor + CapacitorCordova)
  |
  v
[CI only: xcodebuild build, unsigned]
  |
  v
[Release: archive -> export IPA -> upload to App Store Connect]
  |
  v
Upload IPA as GitHub Actions artifact (90-day retention)
```

---

## Files

| File | Purpose |
|---|---|
| `.github/workflows/build-and-publish.yml` | GitHub Actions workflow |
| `ExportOptions.plist` | Tells `xcodebuild -exportArchive` to export for App Store |
| `iPadDx.xcodeproj/xcshareddata/xcschemes/iPadDx.xcscheme` | Shared scheme so CI can discover the build target |
| `Podfile` | Root CocoaPods — Capacitor + CapacitorCordova |
| `Bridges/rn_bridge/ios/Podfile` | React Native CocoaPods (separate project) |
| `Bridges/rn_bridge/package.json` | React Native npm dependencies |
| `Bridges/capacitor_bridge/package.json` | Capacitor npm dependencies |

---

## Troubleshooting

### "No signing certificate found"
- Verify `APPLE_CERTIFICATE_BASE64` is correct: `echo "$SECRET" | base64 --decode > test.p12` and try opening it
- Make sure the provisioning profile matches the certificate

### "No provisioning profile"
- Regenerate the profile at developer.apple.com after adding all entitlements
- Ensure it's an **App Store** profile, not Development

### "Scheme not found"
- The shared scheme must be committed: `iPadDx.xcodeproj/xcshareddata/xcschemes/iPadDx.xcscheme`
- Make sure `.gitignore` is not excluding `xcshareddata`

### Build fails on CocoaPods
- `Podfile.lock` should be committed for reproducible builds
- The `pod install --repo-update` step fetches the latest specs

### Flutter framework not found
- Ensure Flutter SDK is available on the runner (the `subosito/flutter-action@v2` step handles this)
- Check that `flutter build ios-framework` produces output in `build/flutter_frameworks/Release/`

### React Native build fails
- Check `Bridges/rn_bridge/ios/Podfile.lock` is committed
- The Folly `Demangle.cpp` patch in the Podfile post_install handles Xcode 16.3+ compatibility
- If `hermes.xcframework` is not found, check the Pods cache path

### main.jsbundle missing
- The `npx react-native bundle` step must run before the main app build
- Check that `Bridges/rn_bridge/index.js` exists and is valid

### Upload fails
- The workflow tries multiple upload methods: `xcodebuild -exportArchive` with auth keys, then `xcrun xcapi`, then `iTMSTransporter`
- If all fail, download the IPA artifact from the Actions run and upload manually via [Transporter.app](https://apps.apple.com/us/app/transporter/id1450874784)
- Verify your API key has **App Manager** access level

---

## Version Bumping

Before pushing a release tag, bump the version:

- **`MARKETING_VERSION`** (e.g., `1.0.0`) — what users see on the App Store
- **`CURRENT_PROJECT_VERSION`** (e.g., `2`) — must increment with each upload

You can do this in Xcode (General tab) or edit `iPadDx.xcodeproj/project.pbxproj` directly.
