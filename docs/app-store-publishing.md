# Publishing iPadDx to the Apple App Store

A step-by-step guide covering everything needed to submit iPadDx to the App Store.

---

## Prerequisites

- [ ] Apple Developer Program membership ($99/year) -- you already have this (Team: Z86ZAY4JRW)
- [ ] Xcode 15.0+ with current command line tools
- [ ] Physical iPad for final testing (simulators not accepted for App Review)
- [ ] All entitlements approved by Apple before submission

## 1. Entitlements & Capabilities

iPadDx uses restricted entitlements that require Apple approval before the app can pass review.

| Entitlement | Key | Status | Action |
|---|---|---|---|
| Multicast Networking | `com.apple.developer.networking.multicast` | Approved (2026-03-27) | None |
| Wi-Fi Info | `com.apple.developer.networking.wifi-info` | Enabled | Verify in provisioning profile |
| Sustained Execution | `com.apple.developer.sustained-execution` | Enabled | Verify in provisioning profile |
| Increased Memory Limit | `com.apple.developer.kernel.increased-memory-limit` | Enabled | Verify in provisioning profile |
| User Assigned Device Name | `com.apple.developer.device-information.user-assigned-device-name` | Pending | Follow up with Apple -- app works without it (manual name fallback) |

**Important:** If you add new entitlements later, they must be reflected in both:
1. `iPadDx/iPadDx.entitlements` (local file)
2. The App ID configuration on developer.apple.com (Certificates, Identifiers & Profiles)

Then regenerate your provisioning profile (Xcode > Signing & Capabilities > uncheck/recheck "Automatically manage signing", or delete profiles in ~/Library/MobileDevice/Provisioning Profiles/).

## 2. App Store Connect Setup

### Create the App Record

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Click **My Apps** > **+** > **New App**
3. Fill in:
   - **Platform:** iOS
   - **Name:** iPadDx (or your preferred display name, max 30 characters)
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** `com.christianlyons.ipadconnection` (must match Xcode)
   - **SKU:** `ipadconnection` (internal reference, not shown to users)
   - **User Access:** Full Access

### App Information

- **Category:** Utilities (primary), Developer Tools (secondary)
- **Content Rights:** Does not contain third-party content
- **Age Rating:** 4+ (no objectionable content)

## 3. App Privacy

Apple requires a privacy nutrition label. iPadDx collects minimal data:

### Privacy Questionnaire Answers

| Question | Answer |
|---|---|
| Do you or your third-party partners collect data? | **Yes** -- device name, model, OS version (local only) |
| Is data linked to user identity? | **No** |
| Is data used for tracking? | **No** |
| Is data shared with third parties? | **No** |

### Data Types to Declare

- **Device ID** -- Used for connection identification (not linked to identity, not sent off-device)
  - Collection purpose: App Functionality
  - Linked to identity: No
  - Used for tracking: No

That's it. No analytics SDKs, no crash reporting, no network calls to external servers. All data stays on-device and on the local network.

## 4. Prepare the Build

### Version & Build Number

In Xcode, update:
- **MARKETING_VERSION** (e.g., `1.0.0`) -- the version users see
- **CURRENT_PROJECT_VERSION** (e.g., `1`) -- must increment with each upload

These are in the target's Build Settings or General tab.

### App Icons

You need an app icon in the asset catalog (`Assets.xcassets/AppIcon`):
- **1024x1024 px** -- required for App Store listing
- Xcode automatically generates all other sizes from this
- No transparency, no rounded corners (Apple applies the mask)
- Must be a single-layer PNG with no alpha channel

### Launch Screen

iPadDx uses `INFOPLIST_KEY_UILaunchScreen_Generation = YES` (auto-generated). This is fine for review.

### Supported Orientations

Already configured for all 4 orientations (portrait, landscape left/right, upside down). Good for iPad.

### Deployment Target

Currently set to **iPadOS 17.0**. This is fine -- covers all iPads that support the required Network.framework features.

## 5. Screenshots

App Review requires screenshots for each supported device size. For iPad-only apps:

| Device Class | Required Size | Devices |
|---|---|---|
| iPad Pro 12.9" (6th gen) | 2048 x 2732 | 12.9" iPad Pro |
| iPad Pro 11" | 1668 x 2388 | 11" iPad Pro, iPad Air |

**Minimum:** 2 screenshots per size, **maximum:** 10.

**Recommended screenshots:**
1. Device discovery / sidebar with peers
2. Diagnostic dashboard with live metrics
3. Test suite running (phases in progress)
4. Test results with grade
5. Conductor dashboard with fleet
6. Analytics / report view

You can capture these from the simulator, but real device screenshots look better. Use Cmd+S in Simulator or the screenshot button on-device.

### App Preview (Optional)

A 15-30 second video showing the connection and test flow. Not required but helps demonstrate the peer-to-peer functionality.

## 6. App Review Information

### Description (4000 chars max)

Write a clear description explaining:
- What the app does (iPad-to-iPad Bonjour connection diagnostics)
- Who it's for (IT admins, developers, QA teams testing local network setups)
- Key features (6-phase test suite, conductor mode, PDF reports)
- That it works offline / peer-to-peer

### Keywords (100 chars max)

`bonjour,network,diagnostic,ipad,connection,wifi,latency,throughput,test,peer-to-peer`

### Support URL

Required. Can be a GitHub repo URL, a simple webpage, or an email-based support page.

### Privacy Policy URL

Required for all apps. Even for a simple utility, you need one. It can be a basic page stating:
- No personal data is collected
- No data is transmitted off-device
- All connection data stays on the local network
- Device info (model, name) is used only for connection identification

Host this on GitHub Pages, a personal site, or a free static hosting service.

### Review Notes

This is critical for iPadDx because it requires **two iPads** to demonstrate functionality. Write something like:

> This app tests the quality of Bonjour connections between iPads using Apple's Network.framework with TLS-PSK encryption. It requires two iPads on the same local network (or peer-to-peer) to function.
>
> To test: Install on two iPads. Both devices will automatically discover each other. Tap a discovered device to connect, then run the test suite from the dashboard. The app works entirely offline -- no internet connection required.
>
> If you only have one device available, the app will show the discovery/advertising screen but won't be able to demonstrate the connection and testing features.

### Demo Account

Not applicable (no login required).

## 7. Build & Upload

### Archive

1. In Xcode, select **Any iOS Device (arm64)** as the destination (not a simulator)
2. **Product > Archive**
3. Wait for the archive to complete
4. The Organizer window opens automatically

### Validate

1. In the Organizer, select the archive
2. Click **Validate App**
3. Fix any issues:
   - Missing icons
   - Entitlement mismatches
   - Signing issues
   - Invalid architectures

### Upload

1. Click **Distribute App**
2. Choose **App Store Connect**
3. Choose **Upload**
4. Select distribution options:
   - **Strip Swift symbols:** Yes
   - **Upload symbols:** Yes
   - **Manage version and build number:** Yes (or manual)
5. Select the signing certificate and provisioning profile
6. Click **Upload**

### Alternative: Command Line

```bash
# Archive
xcodebuild -scheme iPadDx -destination 'generic/platform=iOS' archive -archivePath ./build/iPadDx.xcarchive

# Export for App Store
xcodebuild -exportArchive -archivePath ./build/iPadDx.xcarchive -exportPath ./build/export -exportOptionsPlist ExportOptions.plist
```

You'd need to create an `ExportOptions.plist` with method `app-store`.

## 8. TestFlight (Recommended First)

Before submitting to App Review, test via TestFlight:

1. After uploading, the build appears in App Store Connect under **TestFlight**
2. It goes through **Processing** (5-30 minutes)
3. Add **Internal Testers** (up to 25, no review needed)
4. Optionally add **External Testers** (up to 10,000, requires Beta App Review)
5. Testers install via the TestFlight app

TestFlight builds expire after 90 days.

This is a good way to:
- Verify the build works on devices you don't own
- Confirm entitlements work with the distribution profile
- Get the Beta App Review process done (faster than full review)

## 9. Submit for Review

1. In App Store Connect, go to your app > **App Store** tab
2. Select the uploaded build
3. Fill in all required fields (description, screenshots, etc.)
4. Set **Pricing and Availability:**
   - Price: Free (or set a price)
   - Availability: All territories (or select specific ones)
5. Click **Submit for Review**

### What Reviewers Check

- App launches without crashing
- All described features work as advertised
- No private API usage
- Proper entitlement usage (multicast, wifi-info, etc.)
- Privacy label matches actual behavior
- No placeholder content
- UI works on all supported devices/orientations

### Common Rejection Reasons for This Type of App

| Reason | Prevention |
|---|---|
| **Guideline 2.1 -- App Completeness:** App doesn't work with one device | Explain in Review Notes that two devices are required |
| **Guideline 4.2 -- Minimum Functionality:** Too simple | Emphasize the 6-phase test suite, conductor mode, analytics, PDF reports |
| **Guideline 5.1.1 -- Data Collection:** Privacy label inaccurate | Declare device ID usage, keep it honest |
| **Guideline 2.5.4 -- Multitasking:** Doesn't support multitasking | Already supports all orientations and split view |

### Review Timeline

- First submission: typically 24-48 hours (can take up to 7 days)
- Updates: usually faster (24 hours)
- If rejected: fix the issues, resubmit, and reply to the rejection in Resolution Center

## 10. Post-Submission Checklist

- [ ] Monitor Resolution Center for reviewer questions
- [ ] If approved, the app goes live automatically (unless you set manual release)
- [ ] Set up **Pricing** if it's not free
- [ ] Consider **App Analytics** in App Store Connect to track downloads
- [ ] Plan for update submissions as you add features

## Quick Reference: Files That Matter for Submission

| Item | Location |
|---|---|
| Bundle ID | `com.christianlyons.ipadconnection` (in project settings) |
| Entitlements | `iPadDx/iPadDx.entitlements` |
| Info.plist | `iPadDx/Info.plist` |
| App Icon | `iPadDx/Assets.xcassets/AppIcon` |
| Version | Build Settings > `MARKETING_VERSION` |
| Build Number | Build Settings > `CURRENT_PROJECT_VERSION` |
| Deployment Target | Build Settings > `IPHONEOS_DEPLOYMENT_TARGET` (17.0) |
| Team ID | `Z86ZAY4JRW` |

---

*Last updated: 2026-03-28*
