import Foundation

enum AppBrand {
    static let name = "MacInspect"
    static var displayName: String { L10n.t("brand.display_name") }
    static let supportFolder = "MacInspect"
    static let legacySupportFolder = "MacCheck"

    /// Public GitHub repository.
    static let repositoryURL = URL(string: "https://github.com/starpeng/MacInspect")!
    static let issuesURL = URL(string: "https://github.com/starpeng/MacInspect/issues")!
    static let releasesURL = URL(string: "https://github.com/starpeng/MacInspect/releases")!

    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    static var versionLabel: String {
        "\(shortVersion) (\(buildNumber))"
    }
}
