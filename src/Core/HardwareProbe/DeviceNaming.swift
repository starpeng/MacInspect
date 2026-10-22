import Foundation

/// 机型友好名解析。
/// Apple Silicon 机器在设备树 `product-name` 节点里直接存了完整营销名（含屏幕尺寸与年份），
/// 例如 "MacBook Pro (14-inch, 2021)"——这是最可靠的离线来源，无需维护庞大的型号对照表。
/// Intel 老机型可能没有该节点，用一张小对照表 + system_profiler 的 machine_name 兜底。
enum DeviceNaming {

    /// 从 IORegistry `product-name` 读原始营销名（英文，如 "MacBook Pro (14-inch, 2021)"）。
    static func rawMarketingName() -> String {
        let output = ShellRunner.run("/usr/sbin/ioreg", ["-ar", "-k", "product-name"])
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              let nameData = plist.first?["product-name"] as? Data
        else { return "" }
        // data 内容是以 NUL 结尾的 ASCII 字符串
        return String(decoding: nameData, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    /// 对外展示名。中文界面会把 inch / 括号本地化；英文保持 Apple 原文。
    static func friendlyName(fallbackMachineName: String, identifier: String) -> String {
        var name = intelFallbackTable[identifier] ?? rawMarketingName()
        if name == identifier || !name.contains(" ") {
            name = intelFallbackTable[identifier] ?? fallbackMachineName
        }
        if name.isEmpty { name = identifier }
        return localizeForUI(name)
    }

    private static func localizeForUI(_ input: String) -> String {
        guard AppLanguage.current.resolvedCode.hasPrefix("zh") else { return input }
        var s = input
        s = s.replacingOccurrences(of: "-inch", with: " 英寸")
        s = s.replacingOccurrences(of: "‑inch", with: " 英寸")
        s = s.replacingOccurrences(of: " (", with: "（")
        s = s.replacingOccurrences(of: "(", with: "（")
        s = s.replacingOccurrences(of: ")", with: "）")
        s = s.replacingOccurrences(of: ", ", with: "，")
        return s
    }

    /// Intel 机型对照表（Intel 的 `product-name` 实测是型号标识而非营销名）。
    /// 覆盖 macOS 14 仍支持的 Intel 机型，未收录的型号会退回家人可读的 machine_name。
    private static let intelFallbackTable: [String: String] = [
        // MacBook Pro
        "MacBookPro15,1": "MacBook Pro (15-inch, 2018)",
        "MacBookPro15,2": "MacBook Pro (13-inch, 2019)",
        "MacBookPro15,3": "MacBook Pro (15-inch, 2019)",
        "MacBookPro15,4": "MacBook Pro (13-inch, 2019)",
        "MacBookPro16,1": "MacBook Pro (16-inch, 2019)",
        "MacBookPro16,2": "MacBook Pro (13-inch, 2020)",
        "MacBookPro16,3": "MacBook Pro (13-inch, 2020)",
        "MacBookPro16,4": "MacBook Pro (16-inch, 2019)",
        // MacBook Air
        "MacBookAir8,1": "MacBook Air (2018)",
        "MacBookAir8,2": "MacBook Air (2019)",
        "MacBookAir9,1": "MacBook Air (2020)",
        // 台式机
        "Macmini8,1": "Mac mini (2018)",
        "iMac19,1": "iMac (27-inch, 2019)",
        "iMac19,2": "iMac (21.5-inch, 2019)",
        "iMac20,1": "iMac (27-inch, 2020)",
        "iMac20,2": "iMac (27-inch, 2020)",
        "iMacPro1,1": "iMac Pro (2017)",
        "MacPro7,1": "Mac Pro (2019)",
    ]
}
