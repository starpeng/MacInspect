# MacInspect 1.3

Hardware identity / enterprise-lock depth, appearance quick switch, and LICENSE retention.

## Downloads

| Build | File | Platforms |
| --- | --- | --- |
| Intel | `MacInspect-1.3-intel.dmg` | Intel Mac (Apple Silicon via Rosetta 2) |
| Apple Silicon | `MacInspect-1.3-apple-silicon.dmg` | M-series Mac |
| Universal | `MacInspect-1.3-universal.dmg` | Both (recommended) |

Requirements: **macOS 14.0+**.

## What’s new

### Specs library & A-number
- Bundled slim `MacSpecs.json` identity catalog from [AppleDB](https://github.com/littlebyteorg/appledb) (+ [Asahi](https://asahilinux.org/docs/hw/devices/device-list/) board codes): A-number, SoC, board, English name only (no CN/EN marketing mix)
- Cross-checks live chip family against the catalog (warns on franken-Mac / board-swap clues)
- Specs / Overview show Model Number (Axxxx) when available; regenerate via `scripts/generate_mac_device_catalog.py`

### Board identity
- Apple Silicon: shows board code / `target-type` (e.g. `J316cAP`), not the opaque device-tree `0a000000` blob
- Intel: still uses classic `Mac-…` board-id when present
- Classic serials: manufacture week plus known plant/region prefix when decodeable

### Enterprise / MDM
- Extra signals: Configuration Lock, JAMF components, ARDAgent, suspicious LaunchDaemons
- MDM profile marker escalates the primary MDM card
- Full `profiles list` still needs admin — Security pane offers **Authorize & list profiles** (enrollment status remains readable without elevation)

### Appearance
- Toolbar quick switch: click cycles Auto → Light → Dark; menu picks explicitly
- Follow System correctly refreshes when macOS appearance changes

### License retention
- MIT © Star Peng: README / NOTICE / About / report footer stress that forks and redistributions must keep `LICENSE`

### Docs
- Security & Lock screenshots (EN / 简体中文, light∩dark diagonal composite) alongside Overview in README

## Install notes
Same as 1.2: open the DMG, drag to Applications. First launch may need right-click → **Open**. Accessibility / camera / mic / Bluetooth prompts unchanged.

## Feedback
Issues: [github.com/starpeng/MacInspect/issues](https://github.com/starpeng/MacInspect/issues)
