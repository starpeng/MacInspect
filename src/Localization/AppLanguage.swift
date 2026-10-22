import Foundation

/// 应用语言偏好。`system` 跟随系统；其余值为 Bundle 内语言包 code（如 `en`、`zh-Hans`）。
///
/// 存储兼容旧版枚举值：`english` / `simplifiedChinese` / `traditionalChinese`。
struct AppLanguage: Hashable, Identifiable, Sendable {
    /// `"system"` 或语言包 code。
    let rawValue: String

    var id: String { rawValue }

    static let system = AppLanguage(rawValue: "system")
    static let storageKey = "appLanguage"

    static var current: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? system.rawValue
        return AppLanguage(stored: raw)
    }

    /// 设置页选项：跟随系统 + 所有已打包语言。
    static var choices: [AppLanguage] {
        [system] + LocaleCatalog.shared.bundledCodes.map { AppLanguage(rawValue: $0) }
    }

    /// 解析后的 BCP-47 语言码（`system` 时映射到受支持语言包）。
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

    /// 从 UserDefaults 读取，并迁移旧枚举值。
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
        // 精确或前缀匹配已打包语言
        if bundled.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "-") }) {
            return bundled.first { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "-") }!
        }
        if bundled.contains("en") { return "en" }
        return bundled.first ?? "en"
    }
}
