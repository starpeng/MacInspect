# MacInspect 1.2

Interactive-check polish, Find My Mac detection, and documentation refresh.

## Downloads

| Build | File | Platforms |
| --- | --- | --- |
| Intel | `MacInspect-1.2-intel.dmg` | Intel Mac (Apple Silicon via Rosetta 2) |
| Apple Silicon | `MacInspect-1.2-apple-silicon.dmg` | M-series Mac |
| Universal | `MacInspect-1.2-universal.dmg` | Both (recommended) |

Requirements: **macOS 14.0+**.

## What’s new

### Find My Mac / Activation Lock
- Detects **Find My Mac** via `FMMEnabled` in addition to `system_profiler` Activation Lock status
- Always shows a result row (no more silent skip when a field is missing)
- Detail pane lists Activation Lock and Find My Mac separately

### Performance stress
- Keeps UI sampling responsive under full CPU load (RunLoop timer + brief worker yields)
- Charts separate CPU / GPU series (no crossed “diagonal” artifact)
- After a run: **OK & save** / **Issue found** / **Run again**; saving returns to the last-result card

### Interactive checks
- Trackpad: pinch / rotate / two-finger scroll capture (ScrollView no longer swallows scroll); per-gesture checklist
- Speaker, Touch ID, Trackpad, Ports, Performance: last-result card + retest (same pattern as mic / camera / disk)
- Disk speed: saving immediately switches to the previous-result view

### Settings · About
- About card: version/build, repository URL, short development notes
- Links to GitHub repository, releases, and issues

### Docs
- Overview screenshots (EN / 简体中文, light∩dark diagonal composite) in README
- Chinese readme: [README.zh-Hans.md](../README.zh-Hans.md)

## Install notes
Same as 1.1: open the DMG, drag to Applications. First launch may need right-click → **Open**. Accessibility / camera / mic / Bluetooth prompts unchanged.

## Feedback
Issues: [github.com/starpeng/MacInspect/issues](https://github.com/starpeng/MacInspect/issues)
