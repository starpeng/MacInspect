import Foundation
import CryptoKit

/// Lightweight report fingerprint — locally recomputable so buyer/seller can match a screenshot to this run.
enum ReportFingerprint {
    static func make(profile: DeviceProfile?, report: MacInspectReport) -> String {
        let serial = profile?.serialNumber ?? ""
        let model = profile?.modelIdentifier ?? ""
        let red = report.redFlags.count
        let warn = report.results.filter { $0.status == .warning }.count
        let payload = [
            serial,
            model,
            "\(report.score)",
            "\(Int(report.generatedAt.timeIntervalSince1970))",
            report.appVersion,
            "\(red)",
            "\(warn)",
            "\(report.results.count)",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
