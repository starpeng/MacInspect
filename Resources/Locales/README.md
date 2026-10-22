# Locales

In-app copy language packs (JSON). Each filename is a BCP-47 language code, for example:

- `en.json`
- `zh-Hans.json`
- `zh-Hant.json`

## Adding a New Language

1. Copy `en.json` to `{code}.json` (e.g., `ja.json`)
2. Translate the value of each key; preserve format placeholders such as `%@` / `%d`
3. Change `_meta.language_name` to the language’s autonym (used for display on the Settings page)
4. Recompile; the new option will automatically appear under Settings → Language

No need to modify the Swift enum.

## Conventions

- Keys use dot notation: `sidebar.overview`, `battery.cycle.title`
- `_meta.*` is metadata and is not displayed as user-facing copy
- If a key is missing, fall back to `en.json`; if it is still missing, display the key itself