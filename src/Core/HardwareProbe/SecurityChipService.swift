import Foundation

/// A8：安全芯片档位识别。用大白话解释含义，避免用户误以为"没有 T2 = 有问题"。
enum SecurityChipTier: Sendable {
    case appleSilicon
    case intelWithT2
    case intelNoT2

    var label: String {
        switch self {
        case .appleSilicon: return L10n.t("security.chip.apple")
        case .intelWithT2: return L10n.t("security.chip.t2")
        case .intelNoT2: return L10n.t("security.chip.no_t2")
        }
    }

    var explanation: String {
        switch self {
        case .appleSilicon: return L10n.t("security.chip.explain.apple")
        case .intelWithT2: return L10n.t("security.chip.explain.t2")
        case .intelNoT2: return L10n.t("security.chip.explain.no_t2")
        }
    }
}

enum SecurityChipService {

    private static func bridgeOSJSON() -> [String: Any] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPiBridgeDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPiBridgeDataType"] as? [[String: Any]],
              let first = items.first
        else { return [:] }
        return first
    }

    static func detectTier() -> SecurityChipTier {
        if HardwareProbe.isAppleSiliconHardware() {
            return .appleSilicon
        }
        let bridge = bridgeOSJSON()
        let modelName = (bridge["ibridge_model_name"] as? String) ?? (bridge["Model Name"] as? String) ?? ""
        if modelName.contains("T2") {
            return .intelWithT2
        }
        return .intelNoT2
    }

    static func runAll() -> [CheckResult] {
        let tier = detectTier()
        return [CheckResult(
            id: "hardware.securityChip",
            title: L10n.t("security.chip.title"),
            status: .pass,
            summary: L10n.t("security.chip.summary", tier.label, tier.explanation),
            rawDetails: [L10n.t("security.chip.tier"): tier.label]
        )]
    }
}
