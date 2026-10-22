# MacInspect 1.0

First public release of **MacInspect** — a local macOS inspection app for used-Mac deals, shop counters, and self-checks. Runs offline by default; no serial numbers, scan results, or reports are uploaded.

Inspiration and prototype from open-source [MacCheck](https://github.com/andyhuo520/MacCheck); independently maintained.

## Downloads

| Build | File | Platforms |
| --- | --- | --- |
| Intel | `MacInspect-1.0-intel.dmg` | Intel Mac (Apple Silicon via Rosetta 2) |
| Apple Silicon | `MacInspect-1.0-apple-silicon.dmg` | M-series Mac |
| Universal | `MacInspect-1.0-universal.dmg` | Both (recommended) |

Requirements: **macOS 14.0+**.

## Highlights

### Automatic scan
- Model, chip, memory, architecture, macOS version, serial, model year / production hints
- **Graphics**: integrated / discrete GPUs and VRAM when reported (Apple Silicon = on-chip GPU; discrete mainly on some Intel machines)
- Battery health & cycle count, storage / SMART-oriented status, network & Bluetooth, ports
- Trade-risk flags: MDM, Activation Lock / Apple ID hints, security chip tier (Apple Silicon / T2 / none)

### Interactive checks
- Keyboard (fullscreen key lighting; Accessibility for third-party hotkey blocking)
- Display (solids, grayscale, checkerboard; previous / next; flag issues)
- Speakers / headphones, microphone, camera, Touch ID, trackpad
- Disk read/write speed, performance stress (**30 / 60 / 120 / 300 s**), per-port live plug test
- Every interactive item can be **skipped** and recorded as skipped in the report

### Reports & UX
- Export PDF or PNG long-form report (local only)
- Appearance: system / light / dark
- In-app language: English, Simplified Chinese, Traditional Chinese (JSON locale packs)

### AI hints
- Rough local-LLM fit guidance from RAM (and discrete VRAM on Intel when present)

## Packaging & tooling
- Product / scheme / DMG: **MacInspect**; scripts: `scripts/run.sh`, `scripts/release.sh`
- xcodegen + committed `MacInspect.xcodeproj`
- Optional Developer ID sign + Apple notarization

## Install notes
1. Open the DMG and drag `MacInspect.app` to Applications.
2. If Gatekeeper blocks first launch: right-click → **Open**, or allow under **System Settings → Privacy & Security**.
3. Keyboard global-hotkey blocking needs **Accessibility** (re-grant after re-sign / rebuild).
4. Camera, microphone, and Bluetooth prompt as needed.

Quarantine “damaged” false positive (trusted source only):

```bash
sudo xattr -rd com.apple.quarantine /Applications/MacInspect.app
```

## Credits
- Prototype lineage: [MacCheck](https://github.com/andyhuo520/MacCheck)
- App icon generated with Google Gemini — prompt in [design/README.md](../design/README.md)

## Feedback
Issues: [github.com/starpeng/MacInspect/issues](https://github.com/starpeng/MacInspect/issues)
