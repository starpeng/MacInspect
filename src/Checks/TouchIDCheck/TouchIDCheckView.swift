import SwiftUI
import LocalAuthentication

/// B10: Touch ID — one biometric prompt to verify the sensor.
struct TouchIDCheckView: View {
    let onComplete: (CheckResult) -> Void
    @State private var statusText = L10n.t("check.touchid.prompt")
    @State private var available = true
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "touchid",
                title: L10n.t("check.touchid.title"),
                subtitle: L10n.t("check.touchid.subtitle")
            )

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

            DS.Divider()

            Button(L10n.t("common.skip")) {
                onComplete(CheckResult(id: "touchID", title: L10n.t("check.touchid.item"), status: .skipped,
                    summary: L10n.t("check.touchid.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.touchid.item"))
        .onAppear { checkAvailability() }
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
                    onComplete(CheckResult(id: "touchID", title: L10n.t("check.touchid.item"), status: .pass,
                        summary: L10n.t("check.touchid.ok")))
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
