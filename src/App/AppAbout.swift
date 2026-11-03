import AppKit
import Foundation

/// System About panel (MacInspect → About MacInspect).
enum AppAbout {
    @MainActor
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2

        let body = [
            L10n.t("about.credits.blurb", AppBrand.name),
            "",
            L10n.t("about.credits.notes"),
            "",
            L10n.t("about.credits.license"),
            "",
            AppBrand.repositoryURL.absoluteString,
        ].joined(separator: "\n")

        let credits = NSAttributedString(
            string: body,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )

        // Copyright comes from Info.plist `NSHumanReadableCopyright` (localized via InfoPlist.strings).
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppBrand.name,
            .applicationVersion: AppBrand.shortVersion,
            .version: AppBrand.buildNumber,
            .credits: credits,
        ]
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}
