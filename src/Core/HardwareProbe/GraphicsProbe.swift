import Foundation

/// One GPU summary from system_profiler SPDisplaysDataType.
struct GPUInfo: Sendable, Equatable {
    let name: String
    /// VRAM GB. Discrete = dedicated; iGPU = shared (don't treat as discrete budget).
    let vramGB: Double
    let isDiscrete: Bool
    let metalSupported: Bool
}

/// List GPUs / VRAM. On Intel, prefer discrete VRAM for local LLM sizing.
/// `system_profiler` is slow — cache for process lifetime.
enum GraphicsProbe {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var gpus: [GPUInfo]?
    }
    private static let cache = Cache()

    static func allGPUs() -> [GPUInfo] {
        cache.lock.lock()
        if let cached = cache.gpus {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()

        let fetched = fetchAllGPUs()

        cache.lock.lock()
        cache.gpus = fetched
        cache.lock.unlock()
        return fetched
    }

    /// Largest discrete dedicated VRAM (GB); nil if none.
    static func primaryDiscreteGPU() -> GPUInfo? {
        allGPUs()
            .filter(\.isDiscrete)
            .max { $0.vramGB < $1.vramGB }
    }

    private static func fetchAllGPUs() -> [GPUInfo] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cards = json["SPDisplaysDataType"] as? [[String: Any]]
        else { return [] }

        return cards.compactMap { card in
            let name = (card["sppci_model"] as? String)
                ?? (card["_name"] as? String)
                ?? L10n.t("graphics.unknown")

            let sharedRaw = (card["spdisplays_vram_shared"] as? String)
                ?? (card["_spdisplays_vram"] as? String)
            let dedicatedRaw = card["spdisplays_vram"] as? String

            let bus = (card["sppci_bus"] as? String) ?? ""
            let vendor = ((card["spdisplays_vendor"] as? String) ?? "").lowercased()
            let metal = (card["spdisplays_metal"] as? String)?.contains("supported") == true

            // Discrete: dedicated VRAM field, or PCIe-attached (AMD/NVIDIA).
            let looksPCIe = bus.contains("pcie")
            let looksIntelIGPU = name.localizedCaseInsensitiveContains("Intel UHD")
                || name.localizedCaseInsensitiveContains("Intel Iris")
                || name.localizedCaseInsensitiveContains("Intel HD")
                || vendor == "intel"

            var isDiscrete = false
            var vramGB: Double = 0

            if let dedicatedRaw, let gb = parseMemoryGB(dedicatedRaw), gb > 0 {
                // Shared + Intel iGPU → still shared
                if looksIntelIGPU, sharedRaw != nil, !looksPCIe {
                    isDiscrete = false
                    vramGB = parseMemoryGB(sharedRaw!) ?? gb
                } else {
                    isDiscrete = true
                    vramGB = gb
                }
            } else if let sharedRaw, let gb = parseMemoryGB(sharedRaw) {
                isDiscrete = false
                vramGB = gb
            } else if looksPCIe, !looksIntelIGPU {
                // PCIe GPU without a readable size — still treat as discrete.
                isDiscrete = true
                vramGB = 0
            } else {
                // Apple Silicon often omits VRAM fields (unified memory). Keep the GPU row.
                let looksApple = name.localizedCaseInsensitiveContains("Apple")
                    || vendor.contains("apple")
                guard looksApple || metal else { return nil }
                isDiscrete = false
                vramGB = 0
            }

            // Dual-GPU Intel machines: iGPU stays integrated even if a VRAM key exists.
            if looksIntelIGPU && !looksPCIe {
                isDiscrete = false
            }

            return GPUInfo(name: name, vramGB: vramGB, isDiscrete: isDiscrete, metalSupported: metal)
        }
    }

    /// Specs / report lines: name + integrated/discrete (+ VRAM when known).
    static func profileEntries() -> [DeviceGraphicsInfo] {
        allGPUs().map { gpu in
            let detail: String
            if gpu.isDiscrete {
                detail = gpu.vramGB > 0
                    ? L10n.t("specs.gpu.discrete_vram", String(format: "%.0f", gpu.vramGB))
                    : L10n.t("specs.gpu.discrete")
            } else if gpu.vramGB > 0 {
                detail = L10n.t("specs.gpu.integrated_shared", String(format: "%.0f", gpu.vramGB))
            } else {
                detail = L10n.t("specs.gpu.integrated")
            }
            return DeviceGraphicsInfo(name: gpu.name, detail: detail)
        }
    }

    /// Parse "8 GB" / "1536 MB" / "8192 MB" → GB.
    static func parseMemoryGB(_ raw: String) -> Double? {
        let lowered = raw.lowercased().replacingOccurrences(of: ",", with: "")
        let number = lowered.filter { $0.isNumber || $0 == "." }
        guard let value = Double(number), value > 0 else { return nil }
        if lowered.contains("mb") {
            return value / 1024.0
        }
        // Default unit: GB
        return value
    }
}
