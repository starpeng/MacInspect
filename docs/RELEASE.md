# Release

## Version numbers

Maintained in `src/App/Info.plist`:

- `CFBundleShortVersionString`: marketing version, e.g. `1.0`
- `CFBundleVersion`: build number, e.g. `4`

If you regenerate the Xcode project with `xcodegen`, keep the same fields in `project.yml` in sync with `Info.plist`.

`scripts/release.sh` reads `CFBundleShortVersionString` for the DMG name — no need to hardcode the version in the script.

## Architectures & artifacts

| Target | ARCHS | Runs on | DMG |
| --- | --- | --- | --- |
| Intel | `x86_64` | Intel Mac; Apple Silicon via Rosetta 2 | `MacInspect-1.0-intel.dmg` |
| Apple Silicon | `arm64` | Apple silicon Macs | `MacInspect-1.0-apple-silicon.dmg` |
| Universal | `arm64 x86_64` | Both | `MacInspect-1.0-universal.dmg` |

Prefer Universal for public releases. Ship Intel / Apple Silicon separately when size or audience requires it.

## Local packaging

```bash
./scripts/release.sh intel
./scripts/release.sh apple-silicon
./scripts/release.sh universal

# or all three
for arch in intel apple-silicon universal; do
  ./scripts/release.sh "$arch"
done
```

Default output under `artifacts/dist/`:

```text
artifacts/dist/MacInspect-1.0-intel.dmg
artifacts/dist/MacInspect-1.0-apple-silicon.dmg
artifacts/dist/MacInspect-1.0-universal.dmg
```

Custom output directory:

```bash
MACINSPECT_OUTPUT_DIR="$PWD/artifacts/dist" ./scripts/release.sh universal
```

The script:

1. Regenerates the project if `xcodegen` is installed
2. Release-builds with the selected `ARCHS`
3. Checks architecture with `lipo -info`
4. Signs, notarizes, and staples when a Developer ID cert is available
5. Otherwise produces an ad-hoc DMG

Full build details: [BUILD.md](BUILD.md).

> You can cross-compile arm64 on Intel, but you cannot run it there. Validate Apple silicon builds on an M-series Mac before release.

## Signing & notarization

For public distribution you need:

1. An Apple Developer account
2. A `Developer ID Application` certificate in Keychain
3. Stored notarytool credentials

```bash
xcrun notarytool store-credentials "macinspect-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

Optional env:

```bash
export MACINSPECT_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export MACINSPECT_NOTARY_PROFILE="macinspect-notary"
```

The script always passes `src/App/MacInspect.entitlements` so camera/mic work under hardened runtime.

## GitHub Release (CI)

Preferred path: push a version tag. Workflow [`.github/workflows/release.yml`](../.github/workflows/release.yml) will:

1. Require `docs/RELEASE_NOTES_<version>.md` (tag `v1.0` → `RELEASE_NOTES_1.0.md`)
2. Require `CFBundleShortVersionString` in `src/App/Info.plist` to match `<version>`
3. Build **intel**, **apple-silicon**, and **universal** DMGs via `scripts/release.sh`
4. Create the GitHub Release with those notes and upload the three DMGs + `SHA256SUMS.txt`

```bash
# After bumping version in Info.plist + project.yml and writing RELEASE_NOTES_1.0.md:
git tag v1.0
git push origin v1.0
```

Without Apple Developer ID secrets on the runner, DMGs are **ad-hoc** (users may need right-click → Open).

### Manual release (optional)

Write `docs/RELEASE_NOTES_<version>.md`. Repo: `starpeng/MacInspect`. Examples assume DMGs in `artifacts/dist/`.

```bash
for arch in intel apple-silicon universal; do
  ./scripts/release.sh "$arch"
done

gh release create v1.0 \
  artifacts/dist/MacInspect-1.0-intel.dmg \
  artifacts/dist/MacInspect-1.0-apple-silicon.dmg \
  artifacts/dist/MacInspect-1.0-universal.dmg \
  artifacts/dist/SHA256SUMS.txt \
  --repo starpeng/MacInspect \
  --title "MacInspect 1.0" \
  --notes-file docs/RELEASE_NOTES_1.0.md
```

In the release notes, spell out:

- Intel users → `-intel`
- Apple silicon users → `-apple-silicon`
- Unsure → `-universal`

## Post-release checks

- Release page lists the expected DMG attachments
- Each DMG passes `hdiutil verify`
- After mount, `lipo -info` matches the filename arch
- Signed/notarized builds pass Gatekeeper:

```bash
spctl -a -vv -t exec /Applications/MacInspect.app
```

- App launches and finishes the overview scan on at least one Intel and one Apple silicon Mac
- Report export (PNG / PDF) works
- Keyboard Accessibility flow works (re-sign may require re-granting)
- README install/usage steps still match reality

## User install troubleshooting

If Gatekeeper blocks an ad-hoc or un-notarized first launch: right-click `MacInspect.app` → **Open**, or allow under **System Settings → Privacy & Security**.

Do not tell users to run `sudo spctl --master-disable`. Ship Developer ID + notarization for public builds.

If macOS says the app is “damaged”, after confirming a trusted source and `/Applications` install:

```bash
sudo xattr -rd com.apple.quarantine /Applications/MacInspect.app
```

Keyboard tests need **Accessibility** to capture F1 and other global hotkeys. After ad-hoc re-sign, macOS may require re-checking the toggle; if needed:

```bash
tccutil reset Accessibility cn.starpeng.macinspect
```
