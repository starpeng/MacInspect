import Foundation

/// One row from the slim bundled catalog (`MacSpecs.json`).
/// Language-neutral / English-only fields for cross-check — no marketing prose blobs.
struct MacSpecsEntry: Codable, Sendable {
    /// English marketing name from AppleDB (e.g. "MacBook Pro (16-inch, M1 Max, 2021)").
    var name: String = ""
    /// Enclosure / regulatory A-number (e.g. "A2485").
    var model_no: String = ""
    /// Expected SoC / CPU family label (e.g. "M1 Max", "M4", "Intel").
    var chip: String = ""
    /// Board code: Apple Silicon `JxxxAP` or Intel `Mac-…`.
    var board: String = ""
    /// Display size token when parseable (e.g. "16-inch").
    var screen: String = ""
    /// ISO date string when known (e.g. "2021-10-18").
    var released: String = ""
}

/// Bundled Mac identity catalog (identifier + A-number indexes).
/// Built from AppleDB (+ Asahi board codes); see `scripts/generate_mac_device_catalog.py`.
enum MacSpecsDatabase {
    private struct Root: Codable {
        let models: [String: MacSpecsEntry]
    }

    private static let shared: (models: [String: MacSpecsEntry], byModelNo: [String: MacSpecsEntry], loadError: String?) = {
        guard let url = Bundle.main.url(forResource: "MacSpecs", withExtension: "json") else {
            return ([:], [:], "MacSpecs.json missing from bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let root = try JSONDecoder().decode(Root.self, from: data)
            var byModelNo: [String: MacSpecsEntry] = [:]
            for (_, entry) in root.models {
                let mn = entry.model_no.trimmingCharacters(in: .whitespacesAndNewlines)
                if !mn.isEmpty, byModelNo[mn] == nil {
                    byModelNo[mn] = entry
                }
            }
            return (root.models, byModelNo, nil)
        } catch {
            return ([:], [:], error.localizedDescription)
        }
    }()

    static var loadError: String? { shared.loadError }

    static func lookup(identifier: String) -> MacSpecsEntry? {
        guard !identifier.isEmpty else { return nil }
        return shared.models[identifier]
    }

    static func lookup(modelNo: String) -> MacSpecsEntry? {
        let key = modelNo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return shared.byModelNo[key]
    }

    /// Chip family token used for cross-check (e.g. "M4", "M1", "Intel").
    static func chipFamily(from text: String) -> String? {
        let upper = text.uppercased()
        if upper.contains("INTEL") || upper.contains("XEON") || upper.contains("CORE I") {
            return "Intel"
        }
        // Prefer longer tokens first (M4 before accidental short matches).
        for family in ["M5", "M4", "M3", "M2", "M1"] {
            if upper.contains(family) { return family }
        }
        return nil
    }

    /// True when both sides declare a family and they disagree.
    static func chipFamiliesMismatch(actual: String, expected: String) -> Bool {
        guard let a = chipFamily(from: actual), let e = chipFamily(from: expected) else { return false }
        return a != e
    }
}
