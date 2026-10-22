# MacInspect

Local macOS inspection tool for used-Mac deals, shop counters, and self-checks. Reads hardware, battery, storage, network, security, and ports; runs interactive tests (keyboard, display, audio, mic, camera, trackpad, disk speed, and more); exports PDF / PNG reports.

Runs fully offline by default — no serial numbers, scan results, or reports are uploaded.



## Features

- Model, chip, memory, macOS version, serial, and related identity info
- Battery health, storage, network, Bluetooth, and port discovery
- MDM / Activation Lock / security-chip flags for trade risk
- Interactive checks: keyboard, display patterns, audio, mic, camera, Touch ID, trackpad
- Disk speed, short performance stress, per-port live checks
- Local LLM fit hints from installed RAM
- PDF / PNG report export; system / light / dark appearance
- In-app language: English, Simplified Chinese, Traditional Chinese



## Requirements

- macOS 14.0+
- Apple Silicon or Intel
- Xcode 16+ to build from source (`xcodegen` optional if you edit `project.yml`)



## Install

1. Download a DMG from [Releases](https://github.com/starpeng/MacInspect/releases): `-intel`, `-apple-silicon`, or `-universal`.
2. Drag `MacInspect.app` to Applications.
3. If Gatekeeper blocks first launch: right-click → **Open**, or allow under **System Settings → Privacy & Security**.

Signed + notarized builds are preferred for distribution. Ad-hoc DMGs from the scripts are for local testing.

Quarantine false positive (“damaged”):

```bash
sudo xattr -rd com.apple.quarantine /Applications/MacInspect.app
```



## Usage

1. Launch and wait for the overview scan.
2. Review red / high-risk items first.
3. Run hardware tests from the sidebar.
4. Export a PNG or PDF report.



## Build

```bash
git clone https://github.com/starpeng/MacInspect.git
cd MacInspect

./scripts/run.sh                  # Debug build + launch
# or
./scripts/release.sh universal
```

Release builds, signing, and notarization: [docs/BUILD.md](docs/BUILD.md).  
Release checklist: [docs/RELEASE.md](docs/RELEASE.md).  
Manual test list: [docs/TESTING.md](docs/TESTING.md).

Tag a version to publish via GitHub Actions (`v1.1` → notes `docs/RELEASE_NOTES_1.1.md` + three DMGs):

```bash
git tag v1.1 && git push origin v1.1
```

```text
artifacts/dist/MacInspect-<version>-{intel|apple-silicon|universal}.dmg
```

```bash
export MACINSPECT_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export MACINSPECT_NOTARY_PROFILE="macinspect-notary"
```



## Layout

```text
src/App|Core|Checks|UI|Localization
Resources/Locales/     # en, zh-Hans, zh-Hant JSON
scripts/               # run.sh, release.sh
docs/
```



## Notes

- Assistive checks only — not a substitute for Apple service diagnostics.
- Activation Lock / warranty still need Apple’s servers / site confirmation.
- Keyboard global-hotkey capture needs **Accessibility**; re-sign may require re-granting.



## Credits

Independently maintained. Inspiration and prototype from open-source [MacCheck](https://github.com/andyhuo520/MacCheck).

App icon generated with Google Gemini — see [design/README.md](design/README.md) for the prompt.
