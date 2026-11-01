import Darwin
import Foundation
import IOKit

/// One utilization sample (0…100). `gpu` is nil when IOAccelerator stats are unavailable.
struct LoadSample: Sendable, Equatable {
    var cpu: Double
    var gpu: Double?
}

/// Samples system CPU % via `host_statistics` and GPU % via IOAccelerator PerformanceStatistics.
final class LoadSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPU: host_cpu_load_info?

    func reset() {
        lock.lock()
        previousCPU = nil
        lock.unlock()
    }

    func sample() -> LoadSample {
        LoadSample(cpu: sampleCPU(), gpu: sampleGPU())
    }

    // MARK: - CPU

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        guard let previous = previousCPU else {
            previousCPU = info
            return 0
        }
        previousCPU = info

        let user = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return min(100, max(0, (user + system + nice) / total * 100))
    }

    // MARK: - GPU (IOAccelerator PerformanceStatistics)

    private func sampleGPU() -> Double? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        var best: Double?
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any]
            else { continue }

            let keys = [
                "Device Utilization %",
                "Renderer Utilization %",
                "Tiler Utilization %",
                "In Use System Memory",
            ]
            for key in keys where key.contains("Utilization") {
                if let value = Self.doubleValue(stats[key]) {
                    best = max(best ?? 0, value)
                }
            }
        }
        guard let best else { return nil }
        return min(100, max(0, best))
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let d as Double: return d
        case let f as Float: return Double(f)
        default: return nil
        }
    }
}
