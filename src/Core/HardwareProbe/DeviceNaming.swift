import Foundation

/// Friendly marketing name.
/// Apple Silicon: device-tree `product-name` has the full name (size + year) — best offline source.
/// Older Intel may lack it; fall back to a small map + system_profiler machine_name.
enum DeviceNaming {

    /// Raw marketing name from IORegistry `product-name` (English).
    static func rawMarketingName() -> String {
        let output = ShellRunner.run("/usr/sbin/ioreg", ["-ar", "-k", "product-name"])
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              let nameData = plist.first?["product-name"] as? Data
        else { return "" }
        // NUL-terminated ASCII
        return String(decoding: nameData, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    /// Display name. Chinese UI localizes inch/parens; English keeps Apple's text.
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

    /// Intel map (`product-name` is a model id, not marketing name).
    /// Covers Intel still on macOS 14; unknown → family-readable machine_name.
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
        // Desktops
        "Macmini8,1": "Mac mini (2018)",
        "iMac19,1": "iMac (27-inch, 2019)",
        "iMac19,2": "iMac (21.5-inch, 2019)",
        "iMac20,1": "iMac (27-inch, 2020)",
        "iMac20,2": "iMac (27-inch, 2020)",
        "iMacPro1,1": "iMac Pro (2017)",
        "MacPro7,1": "Mac Pro (2019)",
    ]
}
