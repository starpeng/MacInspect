import Foundation

/// A7: MDM / Activation Lock / Find My Mac — red-flag if any hit (reinstall won't fix).
enum ManagementService {

    private enum Key {
        static let dep = "dep"
        static let enrolled = "enrolled"
        static let profiles = "profiles"
        static let icloud = "icloud"
        static let lockRaw = "lockRaw"
    }

    private static let displayKey: [String: String] = [
        Key.dep: "mgmt.mdm.dep",
        Key.enrolled: "mgmt.mdm.enrolled",
        Key.profiles: "mgmt.mdm.profiles_count",
        Key.icloud: "mgmt.appleid.icloud",
        Key.lockRaw: "mgmt.lock.raw",
    ]

    private static func localizeDetails(_ raw: [String: String]) -> [String: String] {
        RawDetails.localize(raw, using: displayKey)
    }

    // MARK: - MDM

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

    // MARK: - Apple ID / Find My Mac

    private static func isICloudAccountSignedIn() -> Bool {
        let output = ShellRunner.run("/usr/bin/defaults", ["read", "MobileMeAccounts", "Accounts"])
        return !output.isEmpty && output.contains("AccountID")
    }

    // MARK: - Activation Lock

    private static func activationLockStatus() -> String {
        let sp = HardwareProbe.systemProfilerHardwareJSON()
        return (sp["activation_lock_status"] as? String) ?? ""
    }

    // MARK: - Aggregate checks

    static func runAll() -> [CheckResult] {
        var results: [CheckResult] = []

        let mdm = mdmEnrollmentStatus()
        let profiles = installedConfigurationProfilesSummary()
        var mdmDetails: [String: String] = [
            Key.dep: mdm.enrolledViaDEP.map { $0 ? L10n.t("common.yes") : L10n.t("common.no") }
                ?? L10n.t("common.unknown"),
            Key.enrolled: mdm.mdmEnrolled.map { $0 ? L10n.t("common.yes") : L10n.t("common.no") }
                ?? L10n.t("common.unknown"),
        ]
        if let count = profiles.count {
            mdmDetails[Key.profiles] = "\(count)"
        } else {
            mdmDetails[Key.profiles] = L10n.t("mgmt.mdm.profiles_denied")
        }
        let localizedMDM = localizeDetails(mdmDetails)

        if mdm.mdmEnrolled == true {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .redFlag,
                summary: L10n.t("mgmt.mdm.summary.active"),
                rawDetails: localizedMDM,
                isRedFlagHeadline: L10n.t("mgmt.mdm.headline.active")
            ))
        } else if mdm.enrolledViaDEP == true {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .warning,
                summary: L10n.t("mgmt.mdm.summary.dep"),
                rawDetails: localizedMDM,
                isRedFlagHeadline: L10n.t("mgmt.mdm.headline.dep")
            ))
        } else if mdm.mdmEnrolled == nil {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .warning,
                summary: L10n.t("mgmt.mdm.summary.unknown"),
                rawDetails: localizedMDM
            ))
        } else {
            results.append(CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .pass,
                summary: L10n.t("mgmt.mdm.summary.ok"),
                rawDetails: localizedMDM
            ))
        }

        let signedIn = isICloudAccountSignedIn()
        results.append(CheckResult(
            id: "management.appleID",
            title: L10n.t("mgmt.appleid.title"),
            status: signedIn ? .warning : .pass,
            summary: signedIn ? L10n.t("mgmt.appleid.signed_in") : L10n.t("mgmt.appleid.signed_out"),
            rawDetails: localizeDetails([
                Key.icloud: signedIn
                    ? L10n.t("mgmt.appleid.logged_in")
                    : L10n.t("mgmt.appleid.logged_out"),
            ]),
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
                rawDetails: localizeDetails([Key.lockRaw: lockStatus]),
                isRedFlagHeadline: isLocked ? L10n.t("mgmt.lock.headline") : nil
            ))
        }

        return results
    }
}
