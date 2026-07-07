# Building Noir for Your iPhone (Real Device)

You **do not need a separate folder**. This project builds for both simulator and device. When you build for a **real device**, the app uses the full code paths (TMDB, Kingfisher, in-app Community Library browser, etc.). Simulator-only workarounds are wrapped in `#if targetEnvironment(simulator)` and are **not** compiled for device.

## Steps to build and install on your iPhone

1. **Connect your iPhone** to your Mac with a cable (or use same Wi‑Fi if you use wireless debugging).

2. **Trust the computer** on the iPhone if prompted.

3. **Open the project in Xcode**
   - Open `Noir.xcodeproj` (or the workspace) in Xcode.

4. **Select your iPhone as the run destination**
   - In the Xcode toolbar, click the device menu next to the Run button.
   - Choose your connected iPhone (e.g. "Your Name's iPhone") instead of a simulator.
   - If your device doesn’t appear, make sure it’s unlocked and you’ve chosen "Trust This Computer".

5. **Signing**
   - Select the **Noir** target in the project navigator.
   - Open the **Signing & Capabilities** tab.
   - Check **"Automatically manage signing"**.
   - Choose your **Team** (your Apple ID). If none, add one: Xcode → Settings → Accounts → Add Apple ID.
   - Fix any signing errors Xcode shows (e.g. bundle ID conflict; use a unique one if needed).

6. **Build and run**
   - Press **⌘R** (or click the Run button).
   - On first install, the device may say "Untrusted Developer":
     - On the iPhone: **Settings → General → VPN & Device Management** (or **Profiles**), tap your developer profile, then **Trust**.

7. **Run again**  
   After trusting, run from Xcode again (⌘R) or launch **Noir** from the home screen.

## Build for device from the command line

Replace `YOUR_DEVICE_NAME` with your iPhone’s name (e.g. from the Xcode device menu):

```bash
cd /Users/talaxin/Documents/cursor_projs/Noir

# List connected devices (optional)
xcrun xctrace list devices

# Build for generic iOS device
xcodebuild -project Noir.xcodeproj -scheme Noir -destination 'generic/platform=iOS' -configuration Debug build

# The .app will be in:
# build/Release-iphoneos/Noir.app   (if you used -configuration Release)
# Or under DerivedData if you didn’t specify -derivedDataPath
```

To install the built app on a connected device, it’s easiest to use Xcode (Run with the device selected). For automated install you’d use `ios-deploy` or similar.

## Summary

- **Same project** for simulator and device.
- **Simulator**: uses workarounds (no URLSession/Kingfisher/WKWebView load) to avoid iOS 26 simulator crashes.
- **Device**: uses full networking, Kingfisher, and in-app Community Library; no workarounds.

No need to copy files to a new folder; just pick your iPhone as the run destination and build.
