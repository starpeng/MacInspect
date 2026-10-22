# MacInspect — Build & Package

How to build Intel (`x86_64`), Apple Silicon (`arm64`), and Universal binaries, and package them as DMGs.

## 1. Requirements

- Build host: macOS 14 or later
- Xcode 16 or later (this project has been verified with Xcode 26.5)
- Command-line tools:

```bash
xcode-select -p        # should point at Xcode.app/Contents/Developer
xcodebuild -version
```

- Optional: `xcodegen`. `MacInspect.xcodeproj` is committed; regenerate only after editing `project.yml`:

```bash
brew install xcodegen
xcodegen generate
```

- Public distribution also needs an Apple Developer account and a `Developer ID Application` certificate (see §5).

## 2. Architectures

| Target | `ARCHS` | Runs on | Suggested DMG name |
| --- | --- | --- | --- |
| Intel | `x86_64` | Intel Mac; Apple Silicon via Rosetta 2 | `MacInspect-1.0-intel.dmg` |
| Apple Silicon | `arm64` | Apple silicon Macs | `MacInspect-1.0-apple-silicon.dmg` |
| Universal | `arm64 x86_64` | Both | `MacInspect-1.0-universal.dmg` |

Notes:

- Minimum OS is `MACOSX_DEPLOYMENT_TARGET` (currently macOS 14.0).
- Intel builds can run under Rosetta 2 on Apple silicon; performance/behavior may differ from native.
- Apple silicon builds do not run on Intel Macs.
- Prefer Universal for public releases; ship single-arch builds when size or audience requires it.

## 3. Build

Run all commands from the repo root.

### 3.1 Intel (`x86_64`)

```bash
xcodebuild \
  -project MacInspect.xcodeproj \
  -scheme MacInspect \
  -configuration Release \
  -derivedDataPath artifacts/build/release-intel \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Product:

```text
artifacts/build/release-intel/Build/Products/Release/MacInspect.app
```

### 3.2 Apple Silicon (`arm64`)

```bash
xcodebuild \
  -project MacInspect.xcodeproj \
  -scheme MacInspect \
  -configuration Release \
  -derivedDataPath artifacts/build/release-apple-silicon \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Product:

```text
artifacts/build/release-apple-silicon/Build/Products/Release/MacInspect.app
```

> You can cross-compile arm64 on an Intel Mac, but you cannot run it there — test on Apple silicon.
> Likewise, Apple silicon can cross-compile `x86_64`.

### 3.3 Universal (`arm64` + `x86_64`)

```bash
xcodebuild \
  -project MacInspect.xcodeproj \
  -scheme MacInspect \
  -configuration Release \
  -derivedDataPath artifacts/build/release-universal \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Product:

```text
artifacts/build/release-universal/Build/Products/Release/MacInspect.app
```

### 3.4 Verify architecture

```bash
lipo -info artifacts/build/release-intel/Build/Products/Release/MacInspect.app/Contents/MacOS/MacInspect
# Non-fat file: ... is architecture: x86_64

lipo -info artifacts/build/release-apple-silicon/Build/Products/Release/MacInspect.app/Contents/MacOS/MacInspect
# Non-fat file: ... is architecture: arm64

lipo -info artifacts/build/release-universal/Build/Products/Release/MacInspect.app/Contents/MacOS/MacInspect
# Architectures in the fat file: ... are: x86_64 arm64
```

Also check code signing:

```bash
codesign -dv --verbose=4 artifacts/build/release-universal/Build/Products/Release/MacInspect.app
codesign --verify --deep --strict --verbose=2 artifacts/build/release-universal/Build/Products/Release/MacInspect.app
```

Local ad-hoc builds fail Gatekeeper `spctl` checks — expected. Signed + notarized builds should pass:

```bash
spctl -a -vv -t exec artifacts/build/release-universal/Build/Products/Release/MacInspect.app
```

## 4. Package DMG

### 4.1 One-shot script (recommended)

`scripts/release.sh` builds, checks architecture, signs (if a cert is present), creates a DMG, notarizes, and staples:

```bash
./scripts/release.sh intel
./scripts/release.sh apple-silicon
./scripts/release.sh universal
```

Output:

```text
artifacts/dist/MacInspect-1.0-intel.dmg
artifacts/dist/MacInspect-1.0-apple-silicon.dmg
artifacts/dist/MacInspect-1.0-universal.dmg
```

Build all three:

```bash
for arch in intel apple-silicon universal; do
  ./scripts/release.sh "$arch"
done
```

Version comes from `CFBundleShortVersionString` in `src/App/Info.plist`. Override the output directory with (legacy `MACCHECK_*` still works):

```bash
MACINSPECT_OUTPUT_DIR="$PWD/artifacts/dist" ./scripts/release.sh universal
```

Script steps:

1. Run `xcodegen generate` if `xcodegen` is installed
2. Release-build with the selected `ARCHS`
3. Fail if `lipo -info` does not match the requested arch
4. Sign with hardened runtime if a `Developer ID Application` identity exists
5. Create the DMG; notarize and staple when signed
6. Otherwise skip sign/notarize and emit an ad-hoc DMG (runs locally)

Default with no args is `universal`:

```bash
./scripts/release.sh
```

### 4.2 Manual packaging

Intel example:

```bash
mkdir -p artifacts/dist
APP="artifacts/build/release-intel/Build/Products/Release/MacInspect.app"
DMG="artifacts/dist/MacInspect-1.0-intel.dmg"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacInspect" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

hdiutil verify "$DMG"
```

Swap `APP` / `DMG` for `release-apple-silicon` or `release-universal` for the other packages.

## 5. Signing & notarization

### 5.1 Prerequisites

1. Paid Apple Developer account
2. `Developer ID Application` certificate in Keychain  
   (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
3. Store notarytool credentials:

```bash
xcrun notarytool store-credentials "macinspect-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

### 5.2 Via script

```bash
export MACINSPECT_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export MACINSPECT_NOTARY_PROFILE="macinspect-notary"
./scripts/release.sh universal
```

The script signs the app, builds the DMG, submits notarization, then runs `stapler staple` / `stapler validate`.

### 5.3 Manual signing

```bash
codesign --force --options runtime --timestamp \
  --entitlements src/App/MacInspect.entitlements \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  artifacts/build/release-universal/Build/Products/Release/MacInspect.app

codesign --verify --strict --verbose=2 \
  artifacts/build/release-universal/Build/Products/Release/MacInspect.app
```

**Always pass `--entitlements`**, or camera/mic fail under hardened runtime.

Then create the DMG and notarize it:

```bash
xcrun notarytool submit MacInspect-1.0-universal.dmg \
  --keychain-profile "macinspect-notary" --wait
xcrun stapler staple MacInspect-1.0-universal.dmg
xcrun stapler validate MacInspect-1.0-universal.dmg
```

## 6. Troubleshooting

### 6.1 Signing / team errors while building

For local testing, use ad-hoc:

```bash
CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

For real signing, pick a Team in Xcode or pass:

```bash
DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

### 6.2 Wrong architecture in the app

- Ensure `ARCHS=...` is set
- Ensure `ONLY_ACTIVE_ARCH=NO`
- Check the final binary with `lipo -info`, not only Xcode logs
- Universal `ARCHS` must be quoted: `"arm64 x86_64"`

### 6.3 Apple silicon build will not open on Intel

Expected. Intel Macs need `x86_64` or Universal.

### 6.4 Gatekeeper blocks the app

Ad-hoc or un-notarized builds are blocked on first open:

1. Right-click `MacInspect.app` → **Open**
2. Or allow under **System Settings → Privacy & Security** → **Open Anyway**

If macOS says the app is “damaged”, quarantine is usually the cause. After confirming a trusted source and moving the app into `/Applications`:

```bash
sudo xattr -rd com.apple.quarantine /Applications/MacInspect.app
```

**Do not** run `sudo spctl --master-disable`. Ship Developer ID + notarization for public builds.

### 6.5 Notarization fails

```bash
xcrun notarytool log <submission-id> --keychain-profile "macinspect-notary"
```

Common causes: not a Developer ID cert, missing hardened runtime, entitlements mismatch, or the app inside the DMG is unsigned.

### 6.6 Keyboard test asks for Accessibility

Capturing F1 and other global hotkeys needs user consent:

- System Settings → Privacy & Security → Accessibility
Ad-hoc re-signs can look like a new app to macOS; re-grant permission. Reset if needed:

```bash
tccutil reset Accessibility cn.starpeng.macinspect
```

Relaunch and authorize again from the keyboard test.

## 7. Version numbers

Keep these in sync:

- `src/App/Info.plist`: `CFBundleShortVersionString` / `CFBundleVersion`
- `project.yml`: same keys

`scripts/release.sh` reads `CFBundleShortVersionString` from `Info.plist` for the DMG filename.
