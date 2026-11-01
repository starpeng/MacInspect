import SwiftUI
import LocalAuthentication

/// B10: Touch ID — one biometric prompt to verify the sensor.
struct TouchIDCheckView: View {
    @EnvironmentObject private var appModel: AppModel
    let onComplete: (CheckResult) -> Void
    @State private var sessionActive = false
    @State private var statusText = L10n.t("check.touchid.prompt")
    @State private var available = true
    @State private var reason = ""

    private var existingResult: CheckResult? { appModel.result(id: "touchID") }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "touchid",
                title: L10n.t("check.touchid.title"),
                subtitle: L10n.t("check.touchid.subtitle")
            )

            if sessionActive {
                activeSession
            } else if let result = existingResult {
                PreviousResultCard(result: result, showDetails: false)
                Button {
                    beginSession()
                } label: {
                    Label(L10n.t("detail.retest"), systemImage: "arrow.clockwise")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    beginSession()
                } label: {
                    Label(L10n.t("detail.start_test"), systemImage: "touchid")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            DS.Divider()

            Button(L10n.t("common.skip")) {
                finish(CheckResult(
                    id: "touchID",
                    title: L10n.t("check.touchid.item"),
                    status: .skipped,
                    summary: L10n.t("check.touchid.skip_summary")
                ))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.touchid.item"))
        .onAppear {
            checkAvailability()
            if existingResult == nil { beginSession() }
        }
    }

    @ViewBuilder
    private var activeSession: some View {
        if !available {
            InlineNotice(icon: "info.circle.fill", tint: .secondary,
                text: reason.isEmpty ? L10n.t("check.touchid.unsupported") : reason)
        } else {
            Text(statusText).font(DS.Font.body).foregroundStyle(.secondary)
            Button {
                authenticate()
            } label: {
                Label(L10n.t("check.touchid.start"), systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func beginSession() {
        statusText = L10n.t("check.touchid.prompt")
        sessionActive = true
    }

    private func finish(_ result: CheckResult) {
        sessionActive = false
        onComplete(result)
    }

    private func checkAvailability() {
        let context = LAContext()
        var error: NSError?
        if !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            available = false
            if context.biometryType == .none {
                reason = L10n.t("check.touchid.unsupported")
            } else if context.biometryType == .touchID {
                reason = L10n.t("check.touchid.no_enroll")
            }
        }
    }

    private func authenticate() {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        statusText = L10n.t("check.touchid.place")
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: L10n.t("check.touchid.reason")) { success, authError in
            Task { @MainActor in
                if success {
                    finish(CheckResult(
                        id: "touchID",
                        title: L10n.t("check.touchid.item"),
                        status: .pass,
                        summary: L10n.t("check.touchid.ok")
                    ))
                } else {
                    let code = (authError as? LAError)?.code
                    if code == .userCancel || code == .systemCancel {
                        statusText = L10n.t("check.touchid.cancelled")
                    } else {
                        statusText = L10n.t("check.touchid.fail")
                    }
                }
            }
        }
    }
}
