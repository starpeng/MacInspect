import Foundation

/// Loads copy from `Resources/Locales/*.json`. In-app language switch needs no restart; falls back to English.
///
/// To add a locale: drop `{code}.json` under `Resources/Locales/` (copy `en.json`), set `_meta.language_name`;
/// it shows up in Settings automatically.
enum L10n {
    private static let fallbackCode = "en"
    private static let catalog = LocaleCatalog.shared

    static var code: String { AppLanguage.current.resolvedCode }

    static func t(_ key: String) -> String {
        if let value = catalog.string(key, language: code) { return value }
        if code != fallbackCode, let value = catalog.string(key, language: fallbackCode) { return value }
        return key
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = t(key)
        return String(format: format, locale: AppLanguage.current.locale, arguments: args)
    }
}

/// Locale catalog: scans Bundle `*.json` files.
final class LocaleCatalog: @unchecked Sendable {
    static let shared = LocaleCatalog()

    private let lock = NSLock()
    private var cache: [String: [String: String]] = [:]
    private var bundledCodesCache: [String]?

    /// Bundled locale codes (filenames like `en`, `zh-Hans`), stable order.
    var bundledCodes: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let bundledCodesCache { return bundledCodesCache }
        let codes = Self.scanBundledCodes()
        bundledCodesCache = codes
        return codes
    }

    func languageDisplayName(for code: String) -> String {
        if let name = string("_meta.language_name", language: code), !name.isEmpty {
            return name
        }
        return Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }

    func string(_ key: String, language: String) -> String? {
        let table = table(for: language)
        return table[key]
    }

    private func table(for language: String) -> [String: String] {
        lock.lock()
        if let hit = cache[language] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let loaded = Self.loadJSON(language: language)
        lock.lock()
        cache[language] = loaded
        lock.unlock()
        return loaded
    }

    private static func scanBundledCodes() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Locales")
            ?? Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil)
            ?? []
        let preferredOrder = ["en", "zh-Hans", "zh-Hant"]
        let found = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        var ordered = preferredOrder.filter { found.contains($0) }
        ordered.append(contentsOf: found.subtracting(preferredOrder).sorted())
        return ordered
    }

    private static func loadJSON(language: String) -> [String: String] {
        let url =
            Bundle.main.url(forResource: language, withExtension: "json", subdirectory: "Locales")
            ?? Bundle.main.url(forResource: language, withExtension: "json")
        guard let url else {
            assertionFailure("Missing locale file: \(language).json")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: String].self, from: data)
            return raw
        } catch {
            assertionFailure("Failed to load \(language).json: \(error)")
            return [:]
        }
    }
}
