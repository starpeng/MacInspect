# MacInspect 1.1

Maintenance release: clearer detail rows, more reliable appearance switching, and localized scan details.

## Downloads

| Build | File | Platforms |
| --- | --- | --- |
| Intel | `MacInspect-1.1-intel.dmg` | Intel Mac (Apple Silicon via Rosetta 2) |
| Apple Silicon | `MacInspect-1.1-apple-silicon.dmg` | M-series Mac |
| Universal | `MacInspect-1.1-universal.dmg` | Both (recommended) |

Requirements: **macOS 14.0+**.

## What’s new

### Detail & localization
- Scan `rawDetails` use stable keys and resolve through locale packs (en / zh-Hans / zh-Hant)
- Shared `RawDetails.localize` helper across battery, storage, network, ports, management, hardware, and interactive checks
- Key/value detail rows show dotted leaders; odd/even rows use different leader colors for easier reading

### Appearance
- Switching **Dark/Light → Follow System** refreshes the full window (sidebar + cards), not only part of the chrome
- System appearance changes while on Follow System are re-applied without needing to refocus the window

### Sidebar
- Scan status bar no longer overlaps the last sidebar row when the list is long

### Tooling
- `scripts/run.sh --rebuild` / `--clean` regenerates the Xcode project via xcodegen so new Swift files are picked up

## Install notes
Same as 1.0: open the DMG, drag to Applications. First launch may need right-click → **Open**. Accessibility / camera / mic / Bluetooth prompts unchanged.

## Feedback
Issues: [github.com/starpeng/MacInspect/issues](https://github.com/starpeng/MacInspect/issues)
