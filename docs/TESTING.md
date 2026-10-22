# MacInspect — Test checklist

Pre-release self-test and shop inspection flow. Automatic probes can be covered by a build + launch; interactive checks need real Mac hardware.

## Pre-release basics

```bash
# Build Universal at least once; use intel / apple-silicon for single-arch packages
./scripts/release.sh universal

hdiutil verify artifacts/dist/MacInspect-1.0-universal.dmg
lipo -info artifacts/build/release-universal/Build/Products/Release/MacInspect.app/Contents/MacOS/MacInspect
```

If this release includes single-arch packages, verify those too:

```bash
./scripts/release.sh intel
./scripts/release.sh apple-silicon
hdiutil verify artifacts/dist/MacInspect-1.0-intel.dmg
hdiutil verify artifacts/dist/MacInspect-1.0-apple-silicon.dmg
```

Checks:

- App architecture inside the DMG matches the filename (`lipo -info`)
- App launches; overview scan completes
- Every sidebar page opens without broken layout
- Report export produces PNG and PDF
- DMG mounts with `MacInspect.app` and an Applications symlink
- Keyboard test prompts for global-hotkey capture; after grant, F1 etc. do not fire other apps
- Display test covers the full screen; the hint panel is draggable

## Automatic probes

| Module | Expected |
| --- | --- |
| Hardware | Model, serial, chip, memory, arch, macOS version |
| Battery | Cycle / health on laptops; N/A or empty on desktops |
| Security & lock | Security chip, MDM, Apple ID / Activation Lock hints |
| Storage | Capacity, free space, SMART / disk status |
| Network | Wi-Fi / Bluetooth status |
| Ports | Detected USB / Thunderbolt controllers or devices |
| AI models | Local-model fit hints from installed RAM |

## Interactive checks

| Module | Action | Pass criteria |
| --- | --- | --- |
| Keyboard | Full screen; press each physical key | Key highlights; no dead / stuck / double keys |
| Display | Solid colors, grayscale, checkerboard | No obvious dead/bright pixels, bleed, banding |
| Speakers / headphones | Play test tone | L/R and headphone output OK |
| Microphone | Authorize; record or watch levels | Stable input, no abnormal noise floor |
| Camera | Authorize; preview | Clear image; no cover / dead pixels / flicker |
| Touch ID | Follow on-screen prompt | Works or clearly unsupported |
| Trackpad | Click, move, gestures | Click / move / scroll respond |
| Performance | Short stress run | No freeze or thermal / performance red flags |
| Disk speed | Start R/W sample | Speeds shown; no hard failure |
| Per-port live | Plug devices and record | Target ports all recognize devices |

## Privacy & screenshots

Real captures and reports often include serials, device names, and OS versions. Redact before posting to GitHub, sites, or social.

Put fresh screenshots under `docs/assets/` (see that folder’s README); redact sensitive fields.
