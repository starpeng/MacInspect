import AppKit
import Foundation

enum ScreenStage: Int, CaseIterable {
    case black, white, red, green, blue, grayGradient, checkerboard

    var title: String {
        switch self {
        case .black: return L10n.t("check.screen.stage.black")
        case .white: return L10n.t("check.screen.stage.white")
        case .red: return L10n.t("check.screen.stage.red")
        case .green: return L10n.t("check.screen.stage.green")
        case .blue: return L10n.t("check.screen.stage.blue")
        case .grayGradient: return L10n.t("check.screen.stage.gray")
        case .checkerboard: return L10n.t("check.screen.stage.checker")
        }
    }
}

@MainActor
final class ScreenCheckModel: ObservableObject {
    @Published var currentIndex: Int = 0
    @Published var flaggedStages: Set<Int> = []
    @Published var didFinishEarly = false

    let stages = ScreenStage.allCases

    /// Esc-to-exit during screen test (View binds this to finish).
    var onEscape: (() -> Void)?
    private var keyMonitor: Any?

    var currentStage: ScreenStage { stages[currentIndex] }
    var isFirstStage: Bool { currentIndex == 0 }
    var isLastStage: Bool { currentIndex == stages.count - 1 }
    var completedCount: Int { currentIndex + (isLastStage ? 1 : 0) }

    /// Local key monitor so Esc is not treated as “exit fullscreen”.
    func startKeyHandling() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Keep Cmd/Opt/Ctrl chords (e.g. Cmd+Q) as emergency exit.
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.keyCode {
                case 49:  // Space
                    self.advance()
                    return nil
                case 124: // →
                    self.advance()
                    return nil
                case 123: // ←
                    self.goBack()
                    return nil
                case 53:  // Esc
                    self.onEscape?()
                    return nil
                case 3:   // F
                    self.flagCurrent()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    func stopKeyHandling() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func advance() {
        if isLastStage {
            didFinishEarly = false
        } else {
            currentIndex += 1
        }
    }

    func goBack() {
        guard !isFirstStage else { return }
        currentIndex -= 1
    }

    func flagCurrent() {
        flaggedStages.insert(currentIndex)
    }

    func buildResult(exitedEarly: Bool) -> CheckResult {
        let stageNames = flaggedStages.sorted().map { stages[$0].title }
        var details: [String: String] = [
            "stages": "\(exitedEarly ? currentIndex : stages.count) / \(stages.count)",
        ]
        if !stageNames.isEmpty {
            details["flagged"] = stageNames.joined(separator: "; ")
        }
        let localized = RawDetails.localize(details, using: [
            "stages": "check.screen.detail.stages",
            "flagged": "check.screen.detail.flagged",
        ])

        if !flaggedStages.isEmpty {
            let sep = AppLanguage.current.resolvedCode.hasPrefix("zh") ? "、" : ", "
            return CheckResult(
                id: "screen",
                title: L10n.t("check.screen.title"),
                status: .warning,
                summary: L10n.t("check.screen.result.flagged", stageNames.joined(separator: sep)),
                rawDetails: localized
            )
        }
        if exitedEarly {
            return CheckResult(
                id: "screen",
                title: L10n.t("check.screen.title"),
                status: .warning,
                summary: L10n.t("check.screen.result.partial", currentIndex, stages.count),
                rawDetails: localized
            )
        }
        return CheckResult(
            id: "screen",
            title: L10n.t("check.screen.title"),
            status: .pass,
            summary: L10n.t("check.screen.result.ok", stages.count),
            rawDetails: localized
        )
    }
}
