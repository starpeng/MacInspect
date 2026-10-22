import Foundation

/// App language preference. `system` follows the OS; otherwise a bundled locale code (`en`, `zh-Hans`, …).
///
/// Storage also accepts legacy enum values: `english` / `simplifiedChinese` / `traditionalChinese`.
struct AppLanguage: Hashable, Identifiable, Sendable {
    /// `"system"` or a bundled locale code.
    let rawValue: String

    var id: String { rawValue }

    static let system = AppLanguage(rawValue: "system")
    static let storageKey = "appLanguage"

    static var current: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? system.rawValue
        return AppLanguage(stored: raw)
    }

    /// Settings choices: follow system + every bundled locale.
    static var choices: [AppLanguage] {
        [system] + LocaleCatalog.shared.bundledCodes.map { AppLanguage(rawValue: $0) }
    }

    /// Resolved BCP-47 code (`system` maps onto a supported bundled locale).
    var resolvedCode: String {
        if rawValue == "system" {
            return Self.mapSystemToSupported(
                Locale.preferredLanguages.first ?? Locale.current.identifier
            )
        }
        return rawValue
    }

    var locale: Locale { Locale(identifier: resolvedCode) }

    var title: String {
        if rawValue == "system" {
            return L10n.t("settings.language.system")
        }
        return LocaleCatalog.shared.languageDisplayName(for: rawValue)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Load from UserDefaults, migrating legacy enum values.
    init(stored raw: String) {
        let normalized = Self.normalize(raw)
        if normalized != raw {
            UserDefaults.standard.set(normalized, forKey: Self.storageKey)
        }
        self.rawValue = normalized
    }

    private static func normalize(_ raw: String) -> String {
        switch raw {
        case "english": return "en"
        case "simplifiedChinese": return "zh-Hans"
        case "traditionalChinese": return "zh-Hant"
        case "system": return "system"
        default:
            if raw == "system" || LocaleCatalog.shared.bundledCodes.contains(raw) {
                return raw
            }
            return "system"
        }
    }

    static func mapSystemToSupported(_ preferred: String) -> String {
        let lower = preferred.lowercased().replacingOccurrences(of: "_", with: "-")
        let bundled = LocaleCatalog.shared.bundledCodes
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
            return bundled.contains("zh-Hant") ? "zh-Hant" : (bundled.first ?? "en")
        }
        if lower.hasPrefix("zh"), bundled.contains("zh-Hans") {
            return "zh-Hans"
        }
        // Exact or prefix match against bundled codes
        if bundled.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "-") }) {
            return bundled.first { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "-") }!
        }
        if bundled.contains("en") { return "en" }
        return bundled.first ?? "en"
    }
}
