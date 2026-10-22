import Foundation

/// A7：监管与锁定检测——二手交易里最容易被忽视、后果最重的一类问题。
/// 命中任意一项即产生红旗，因为这些问题"重装系统也解决不了"。
enum ManagementService {

    // MARK: - MDM 监管

    private struct MDMEnrollmentStatus {
        var enrolledViaDEP: Bool?
        var mdmEnrolled: Bool?
        var rawOutput: String
    }

    private static func mdmEnrollmentStatus() -> MDMEnrollmentStatus {
        let output = ShellRunner.run("/usr/bin/profiles", ["status", "-type", "enrollment"])
        func flag(after marker: String) -> Bool? {
            guard let range = output.range(of: marker) else { return nil }
            let tail = output[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if tail.hasPrefix("Yes") { return true }
            if tail.hasPrefix("No") { return false }
            return nil
        }
        return MDMEnrollmentStatus(
            enrolledViaDEP: flag(after: "Enrolled via DEP:"),
            mdmEnrolled: flag(after: "MDM enrollment:"),
            rawOutput: output
        )
    }

    private static func installedConfigurationProfilesSummary() -> (count: Int?, rawOutput: String) {
        let output = ShellRunner.run("/usr/bin/profiles", ["list", "-all"])
        let profileLines = output.components(separatedBy: "\n").filter { $0.contains("profileIdentifier") }
        let lowered = output.lowercased()
        if output.isEmpty
            || lowered.contains("requires root")
            || lowered.contains("you need to run this tool as root")
            || lowered.contains("root privileges") {
            return (nil, output)
        }
        return (profileLines.count, output)
    }

    // MARK: - Apple ID / 查找我的 Mac

    private static func isICloudAccountSignedIn() -> Bool {
        let output = ShellRunner.run("/usr/bin/defaults", ["read", "MobileMeAccounts", "Accounts"])
        return !output.isEmpty && output.contains("AccountID")
    }

    // MARK: - 激活锁

    private static func activationLockStatus() -> String {
        let sp = HardwareProbe.systemProfilerHardwareJSON()
        return (sp["activation_lock_status"] as? String) ?? ""
    }

    // MARK: - 汇总检测

    static func runAll() -> [CheckResult] {
        var results: [CheckResult] = []

        let mdm = mdmEnrollmentStatus()
        let profiles = installedConfigurationProfilesSummary()
        var mdmDetails: [String: String] = [
            L10n.t("mgmt.mdm.dep"): mdm.enrolledViaDEP.map { $0 ? L10n.t("common.yes") : L10n.t("common.no") }
                ?? L10n.t("common.unknown"),
            L10n.t("mgmt.mdm.enrolled"): mdm.mdmEnrolled.map { $0 ? L10n.t("common.yes") : L10n.t("common.no") }
                ?? L10n.t("common.unknown"),
        ]
        if let count = profiles.count {
            mdmDetails[L10n.t("mgmt.mdm.profiles_count")] = "\(count)"
        } else {
            mdmDetails[L10n.t("mgmt.mdm.profiles_count")] = L10n.t("mgmt.mdm.profiles_denied")
        }

        if mdm.mdmEnrolled == true {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .redFlag,
                summary: L10n.t("mgmt.mdm.summary.active"),
                rawDetails: mdmDetails,
                isRedFlagHeadline: L10n.t("mgmt.mdm.headline.active")
            ))
        } else if mdm.enrolledViaDEP == true {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .warning,
                summary: L10n.t("mgmt.mdm.summary.dep"),
                rawDetails: mdmDetails,
                isRedFlagHeadline: L10n.t("mgmt.mdm.headline.dep")
            ))
        } else if mdm.mdmEnrolled == nil {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .warning,
                summary: L10n.t("mgmt.mdm.summary.unknown"),
                rawDetails: mdmDetails
            ))
        } else {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .pass,
                summary: L10n.t("mgmt.mdm.summary.ok"),
                rawDetails: mdmDetails
            ))
        }

        let signedIn = isICloudAccountSignedIn()
        results.append(CheckResult(
            id: "management.appleID",
            title: L10n.t("mgmt.appleid.title"),
            status: signedIn ? .warning : .pass,
            summary: signedIn ? L10n.t("mgmt.appleid.signed_in") : L10n.t("mgmt.appleid.signed_out"),
            rawDetails: [
                L10n.t("mgmt.appleid.icloud"): signedIn
                    ? L10n.t("mgmt.appleid.logged_in")
                    : L10n.t("mgmt.appleid.logged_out"),
            ],
            isRedFlagHeadline: signedIn ? L10n.t("mgmt.appleid.headline") : nil
        ))

        let lockStatus = activationLockStatus()
        let isLocked = lockStatus.lowercased().contains("enabled")
        if !lockStatus.isEmpty {
            results.append(CheckResult(
                id: "management.activationLock",
                title: L10n.t("mgmt.lock.title"),
                status: isLocked ? .redFlag : .pass,
                summary: isLocked ? L10n.t("mgmt.lock.on") : L10n.t("mgmt.lock.off"),
                rawDetails: [L10n.t("mgmt.lock.raw"): lockStatus],
                isRedFlagHeadline: isLocked ? L10n.t("mgmt.lock.headline") : nil
            ))
        }

        return results
    }
}
