import Foundation

/// A7: MDM / Activation Lock / Find My Mac — red-flag if any hit (reinstall won't fix).
enum ManagementService {

    private enum Key {
        static let dep = "dep"
        static let enrolled = "enrolled"
        static let profiles = "profiles"
        static let mdmProfiles = "mdmProfiles"
        static let configLock = "configLock"
        static let jamf = "jamf"
        static let ard = "ard"
        static let suspicious = "suspicious"
        static let icloud = "icloud"
        static let lockRaw = "lockRaw"
        static let fmm = "fmm"
        static let al = "activationLock"
    }

    private static let displayKey: [String: String] = [
        Key.dep: "mgmt.mdm.dep",
        Key.enrolled: "mgmt.mdm.enrolled",
        Key.profiles: "mgmt.mdm.profiles_count",
        Key.mdmProfiles: "mgmt.enterprise.mdm_profiles",
        Key.configLock: "mgmt.enterprise.config_lock",
        Key.jamf: "mgmt.enterprise.jamf",
        Key.ard: "mgmt.enterprise.ard",
        Key.suspicious: "mgmt.enterprise.suspicious",
        Key.icloud: "mgmt.appleid.icloud",
        Key.lockRaw: "mgmt.lock.raw",
        Key.fmm: "mgmt.lock.fmm",
        Key.al: "mgmt.lock.al",
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

    private struct ProfilesSummary {
        var count: Int?
        var hasMDMProfile: Bool
        var rawOutput: String
        /// True when `profiles list` needs root and we did not elevate.
        var needsAdmin: Bool
        /// True when the user cancelled the admin password dialog.
        var elevationCancelled: Bool
    }

    private static func installedConfigurationProfilesSummary(elevated: Bool) -> ProfilesSummary {
        let output: String
        var elevationCancelled = false
        if elevated {
            let privileged = ShellRunner.runPrivilegedShell("/usr/bin/profiles list -all")
            if privileged.cancelledOrFailed {
                elevationCancelled = true
                output = privileged.output
            } else {
                output = privileged.output
            }
        } else {
            output = ShellRunner.run("/usr/bin/profiles", ["list", "-all"])
        }

        let profileLines = output.components(separatedBy: "\n").filter { $0.contains("profileIdentifier") }
        let lowered = output.lowercased()
        let hasMDM = lowered.contains("com.apple.mdm")
        let denied = output.isEmpty
            || lowered.contains("requires root")
            || lowered.contains("you need to run this tool as root")
            || lowered.contains("root privileges")
            || elevationCancelled

        if denied {
            return ProfilesSummary(
                count: nil,
                hasMDMProfile: hasMDM,
                rawOutput: output,
                needsAdmin: true,
                elevationCancelled: elevationCancelled
            )
        }
        return ProfilesSummary(
            count: profileLines.count,
            hasMDMProfile: hasMDM,
            rawOutput: output,
            needsAdmin: false,
            elevationCancelled: false
        )
    }

    // MARK: - Enterprise extras (config lock / JAMF / ARD / suspicious daemons)

    private struct EnterpriseExtras {
        var configurationLock: Bool
        var jamfPresent: Bool
        var jamfDetail: String
        var ardRunning: Bool
        var suspiciousDaemons: String
        var mdmProfilePresent: Bool
    }

    private static func probeEnterpriseExtras(mdmProfilePresent: Bool) -> EnterpriseExtras {
        // Keyed lookup — avoids dumping the full I/O registry.
        let configRaw = ShellRunner.run("/usr/sbin/ioreg", ["-r", "-k", "ConfigurationURL"])
        let configurationLock = configRaw.localizedCaseInsensitiveContains("ConfigurationURL")

        let jamfPaths = [
            "/Library/LaunchDaemons/com.jamfsoftware.jamf.daemon.plist",
            "/usr/local/bin/jamf",
            "/Library/Preferences/com.jamfsoftware.jamf.plist",
        ]
        let foundJamf = jamfPaths.filter { FileManager.default.fileExists(atPath: $0) }
        let jamfPresent = !foundJamf.isEmpty

        // pgrep -q only sets exit status; ShellRunner exposes stdout — list PIDs instead.
        let ardList = ShellRunner.run("/usr/bin/pgrep", ["-x", "ARDAgent"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ardRunning = !ardList.isEmpty

        let daemons = ShellRunner.run("/bin/ls", ["/Library/LaunchDaemons"])
        let suspicious = daemons
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                guard !name.isEmpty else { return false }
                let lower = name.lowercased()
                return lower.contains("bypass")
                    || lower.contains("mdm")
                    || lower.contains("activation")
                    || lower.contains("unlock")
            }
            .joined(separator: " ")

        return EnterpriseExtras(
            configurationLock: configurationLock,
            jamfPresent: jamfPresent,
            jamfDetail: foundJamf.joined(separator: " "),
            ardRunning: ardRunning,
            suspiciousDaemons: suspicious,
            mdmProfilePresent: mdmProfilePresent
        )
    }

    private static func enterpriseExtrasResult(_ extras: EnterpriseExtras) -> CheckResult {
        let on = L10n.t("common.yes")
        let off = L10n.t("common.no")
        var details: [String: String] = [
            Key.configLock: extras.configurationLock ? on : off,
            Key.jamf: extras.jamfPresent ? on : off,
            Key.ard: extras.ardRunning ? on : off,
            Key.mdmProfiles: extras.mdmProfilePresent ? on : off,
            Key.suspicious: extras.suspiciousDaemons.isEmpty ? off : extras.suspiciousDaemons,
        ]
        if extras.jamfPresent, !extras.jamfDetail.isEmpty {
            details[Key.jamf] = extras.jamfDetail
        }

        // MDM profile hits are reported on the primary MDM card — avoid a second red flag here.
        let critical = extras.configurationLock || extras.jamfPresent
            || !extras.suspiciousDaemons.isEmpty
        if critical {
            var parts: [String] = []
            if extras.configurationLock { parts.append(L10n.t("mgmt.enterprise.hit.config_lock")) }
            if extras.jamfPresent { parts.append(L10n.t("mgmt.enterprise.hit.jamf")) }
            if !extras.suspiciousDaemons.isEmpty { parts.append(L10n.t("mgmt.enterprise.hit.suspicious")) }
            return CheckResult(
                id: "management.enterpriseLocks",
                title: L10n.t("mgmt.enterprise.title"),
                status: .redFlag,
                summary: parts.joined(separator: " · "),
                rawDetails: localizeDetails(details),
                isRedFlagHeadline: L10n.t("mgmt.enterprise.headline")
            )
        }
        if extras.ardRunning {
            return CheckResult(
                id: "management.enterpriseLocks",
                title: L10n.t("mgmt.enterprise.title"),
                status: .warning,
                summary: L10n.t("mgmt.enterprise.ard_running"),
                rawDetails: localizeDetails(details)
            )
        }
        return CheckResult(
            id: "management.enterpriseLocks",
            title: L10n.t("mgmt.enterprise.title"),
            status: .pass,
            summary: L10n.t("mgmt.enterprise.ok"),
            rawDetails: localizeDetails(details)
        )
    }

    // MARK: - Apple ID / Find My Mac

    /// Signed-in Apple Account for the console user.
    /// macOS 27 emptied MobileMeAccounts; use appleaccount cache + DS idms link instead.
    private static func appleAccountStatus() -> (signedIn: Bool, displayName: String?) {
        // 1) Pre-27: MobileMeAccounts still has Accounts / AccountID.
        let mobileMe = ShellRunner.run("/usr/bin/defaults", ["read", "MobileMeAccounts", "Accounts"])
        if mobileMe.contains("AccountID") || mobileMe.contains("AccountDescription") {
            return (true, mobileMeAccountName(from: mobileMe))
        }

        // 2) macOS 27+: com.apple.appleaccount.informationcache
        let cache = ShellRunner.run("/usr/bin/defaults", ["read", "com.apple.appleaccount.informationcache"])
        if cacheIndicatesSignedIn(cache) {
            return (true, defaultsString(cache, key: "AAAccountFullName"))
        }

        // 3) Directory Services: local user linked to Apple ID (idms).
        let user = NSUserName()
        let recordName = ShellRunner.run("/usr/bin/dscl", [".", "-read", "/Users/\(user)", "RecordName"])
        if recordName.contains("com.apple.idms.appleid.prd.") {
            return (true, nil)
        }
        let altIDs = ShellRunner.run("/usr/bin/dscl", [".", "-read", "/Users/\(user)", "AltSecurityIdentities"])
        if altIDs.contains("com.apple.idms.appleid.prd.") {
            return (true, nil)
        }

        // 4) Older LinkedIdentity (still used on some 15.x hosts).
        let linked = ShellRunner.run("/usr/bin/dscl", [
            ".", "-readpl", "/Users/\(user)",
            "dsAttrTypeNative:LinkedIdentity",
            "appleid.apple.com:linked identities:0:full name",
        ])
        let linkedName = linked
            .components(separatedBy: "full name: ")
            .dropFirst()
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !linkedName.isEmpty, !linked.lowercased().contains("error") {
            return (true, linkedName)
        }

        return (false, nil)
    }

    private static func cacheIndicatesSignedIn(_ defaultsOutput: String) -> Bool {
        let normalized = defaultsOutput
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ";", with: "")
        return normalized.contains("AAIsAccountSignedIn=1")
            || normalized.contains("AAIsAccountSignedIn=true")
            || normalized.contains("AAPrimaryAccountSignInState=1")
    }

    private static func defaultsString(_ defaultsOutput: String, key: String) -> String? {
        // Match: Key = "Value";  or  Key = Value;
        let pattern = #"\#(NSRegularExpression.escapedPattern(for: key))\s*=\s*\"?([^\";\n]+)\"?\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(defaultsOutput.startIndex..., in: defaultsOutput)
        guard let match = regex.firstMatch(in: defaultsOutput, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: defaultsOutput) else { return nil }
        let value = String(defaultsOutput[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func mobileMeAccountName(from accountsOutput: String) -> String? {
        defaultsString(accountsOutput, key: "AccountDescription")
            ?? defaultsString(accountsOutput, key: "DisplayName")
    }

    // MARK: - Find My Mac / Activation Lock

    private struct FindMyProbe {
        /// Raw `activation_lock_status` from system_profiler (may be empty).
        var activationLockRaw: String
        /// Parsed Activation Lock; nil = unknown.
        var activationLockOn: Bool?
        /// `FMMEnabled` from `/Library/Preferences/com.apple.FindMyMac.plist`.
        var findMyMacOn: Bool?
    }

    private static func activationLockRawFromProfiler() -> String {
        let sp = HardwareProbe.systemProfilerHardwareJSON()
        if let json = sp["activation_lock_status"] as? String, !json.isEmpty {
            return json
        }
        // Fallback: text output (some hosts omit the JSON key under load / older OS).
        let text = ShellRunner.run("/usr/sbin/system_profiler", ["SPHardwareDataType"])
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("activation lock status:") else { continue }
            return trimmed
                .split(separator: ":", maxSplits: 1)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ""
    }

    /// Parse profiler strings like `activation_lock_enabled` / `Disabled` / `Enabled`.
    /// Check "disabled" before "enabled" so we never misread substrings.
    private static func parseOnOff(_ raw: String) -> Bool? {
        let s = raw.lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("disabled") || s.contains("off") || s.contains("关闭") || s.contains("關閉") {
            return false
        }
        if s.contains("enabled") || s.hasSuffix(": on") || s == "on"
            || s.contains("开启") || s.contains("開啟") || s.contains("已启用") || s.contains("已啟用") {
            return true
        }
        return nil
    }

    private static func findMyMacPlistEnabled() -> Bool? {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.FindMyMac.plist")
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any],
              dict.keys.contains("FMMEnabled") else { return nil }
        if let b = dict["FMMEnabled"] as? Bool { return b }
        if let n = dict["FMMEnabled"] as? NSNumber { return n.boolValue }
        if let s = dict["FMMEnabled"] as? String {
            let lower = s.lowercased()
            if ["1", "true", "yes"].contains(lower) { return true }
            if ["0", "false", "no"].contains(lower) { return false }
        }
        return nil
    }

    private static func probeFindMy() -> FindMyProbe {
        let raw = activationLockRawFromProfiler()
        return FindMyProbe(
            activationLockRaw: raw,
            activationLockOn: parseOnOff(raw),
            findMyMacOn: findMyMacPlistEnabled()
        )
    }

    private static func findMyResult(_ probe: FindMyProbe) -> CheckResult {
        let onLabel = L10n.t("common.yes")
        let offLabel = L10n.t("common.no")
        let unknown = L10n.t("common.unknown")

        var details: [String: String] = [
            Key.al: probe.activationLockOn.map { $0 ? onLabel : offLabel } ?? unknown,
            Key.fmm: probe.findMyMacOn.map { $0 ? onLabel : offLabel } ?? unknown,
        ]
        if !probe.activationLockRaw.isEmpty {
            details[Key.lockRaw] = probe.activationLockRaw
        }

        // Either signal on → treat as Find My / lock risk for a used-Mac check.
        let anyOn = (probe.activationLockOn == true) || (probe.findMyMacOn == true)
        let bothOff = (probe.activationLockOn == false)
            && (probe.findMyMacOn == false || probe.findMyMacOn == nil)
        let known = probe.activationLockOn != nil || probe.findMyMacOn != nil

        if anyOn {
            return CheckResult(
                id: "management.activationLock",
                title: L10n.t("mgmt.lock.title"),
                status: .redFlag,
                summary: L10n.t("mgmt.lock.on"),
                rawDetails: localizeDetails(details),
                isRedFlagHeadline: L10n.t("mgmt.lock.headline")
            )
        }
        if bothOff {
            return CheckResult(
                id: "management.activationLock",
                title: L10n.t("mgmt.lock.title"),
                status: .pass,
                summary: L10n.t("mgmt.lock.off"),
                rawDetails: localizeDetails(details)
            )
        }
        // No usable signal — still surface the row (old code skipped empty → "检查不出来").
        return CheckResult(
            id: "management.activationLock",
            title: L10n.t("mgmt.lock.title"),
            status: .warning,
            summary: known ? L10n.t("mgmt.lock.partial") : L10n.t("mgmt.lock.unknown"),
            rawDetails: localizeDetails(details)
        )
    }

    // MARK: - Aggregate checks

    /// - Parameter elevatedProfileList: when true, prompt for admin to run `profiles list -all`.
    ///   Keep false for automatic scans — enrollment status already works without root.
    static func runAll(elevatedProfileList: Bool = false) -> [CheckResult] {
        var results: [CheckResult] = []

        let mdm = mdmEnrollmentStatus()
        let profiles = installedConfigurationProfilesSummary(elevated: elevatedProfileList)
        results.append(mdmResult(mdm: mdm, profiles: profiles))
        results.append(enterpriseExtrasResult(probeEnterpriseExtras(mdmProfilePresent: profiles.hasMDMProfile)))

        let apple = appleAccountStatus()
        let icloudValue: String = {
            guard apple.signedIn else { return L10n.t("mgmt.appleid.logged_out") }
            if let name = apple.displayName, !name.isEmpty {
                return "\(L10n.t("mgmt.appleid.logged_in")) (\(name))"
            }
            return L10n.t("mgmt.appleid.logged_in")
        }()
        results.append(CheckResult(
            id: "management.appleID",
            title: L10n.t("mgmt.appleid.title"),
            status: apple.signedIn ? .warning : .pass,
            summary: apple.signedIn ? L10n.t("mgmt.appleid.signed_in") : L10n.t("mgmt.appleid.signed_out"),
            rawDetails: localizeDetails([Key.icloud: icloudValue]),
            isRedFlagHeadline: apple.signedIn ? L10n.t("mgmt.appleid.headline") : nil
        ))

        results.append(findMyResult(probeFindMy()))

        return results
    }

    private static func mdmResult(mdm: MDMEnrollmentStatus, profiles: ProfilesSummary) -> CheckResult {
        var mdmDetails: [String: String] = [
            Key.dep: mdm.enrolledViaDEP.map { $0 ? L10n.t("common.yes") : L10n.t("common.no") }
                ?? L10n.t("common.unknown"),
            Key.enrolled: mdm.mdmEnrolled.map { $0 ? L10n.t("common.yes") : L10n.t("common.no") }
                ?? L10n.t("common.unknown"),
        ]
        if let count = profiles.count {
            mdmDetails[Key.profiles] = "\(count)"
        } else if profiles.elevationCancelled {
            mdmDetails[Key.profiles] = L10n.t("mgmt.mdm.profiles_cancelled")
        } else if profiles.needsAdmin {
            mdmDetails[Key.profiles] = L10n.t("mgmt.mdm.profiles_denied")
        } else {
            mdmDetails[Key.profiles] = L10n.t("common.unknown")
        }
        if profiles.hasMDMProfile {
            mdmDetails[Key.mdmProfiles] = L10n.t("common.yes")
        }
        let localizedMDM = localizeDetails(mdmDetails)

        // MDM enrollment remains the primary management card; MDM profile presence escalates to red.
        if mdm.mdmEnrolled == true || profiles.hasMDMProfile {
            return CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .redFlag,
                summary: mdm.mdmEnrolled == true
                    ? L10n.t("mgmt.mdm.summary.active")
                    : L10n.t("mgmt.mdm.summary.profile"),
                rawDetails: localizedMDM,
                isRedFlagHeadline: L10n.t("mgmt.mdm.headline.active")
            )
        }
        if mdm.enrolledViaDEP == true {
            return CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .warning,
                summary: L10n.t("mgmt.mdm.summary.dep"),
                rawDetails: localizedMDM,
                isRedFlagHeadline: L10n.t("mgmt.mdm.headline.dep")
            )
        }
        if mdm.mdmEnrolled == nil {
            return CheckResult(
                id: "management.mdm",
                title: L10n.t("mgmt.mdm.title"),
                status: .warning,
                summary: L10n.t("mgmt.mdm.summary.unknown"),
                rawDetails: localizedMDM
            )
        }
        // Enrollment clear; profile list may still need admin for full certainty.
        let summary: String
        if profiles.needsAdmin || profiles.elevationCancelled {
            summary = L10n.t("mgmt.mdm.summary.ok_profiles_limited")
        } else {
            summary = L10n.t("mgmt.mdm.summary.ok")
        }
        return CheckResult(
            id: "management.mdm",
            title: L10n.t("mgmt.mdm.title"),
            status: .pass,
            summary: summary,
            rawDetails: localizedMDM
        )
    }
}
