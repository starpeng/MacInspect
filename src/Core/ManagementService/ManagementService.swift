import Foundation

/// A7: MDM / Activation Lock / Find My Mac — red-flag if any hit (reinstall won't fix).
enum ManagementService {

    private enum Key {
        static let dep = "dep"
        static let enrolled = "enrolled"
        static let profiles = "profiles"
        static let icloud = "icloud"
        static let lockRaw = "lockRaw"
        static let fmm = "fmm"
        static let al = "activationLock"
    }

    private static let displayKey: [String: String] = [
        Key.dep: "mgmt.mdm.dep",
        Key.enrolled: "mgmt.mdm.enrolled",
        Key.profiles: "mgmt.mdm.profiles_count",
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
}
