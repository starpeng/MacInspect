import SwiftUI

/// Visual keyboard test: press a key → light it and keep "tested". Not a typing field.
struct KeyboardCheckView: View {
    @StateObject private var model = KeyboardTestModel()
    let onFinish: (CheckResult) -> Void

    private let keyUnit: CGFloat = 46
    private let keySpacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 28) {
            header
            if model.needsAccessibilityPermission {
                accessibilityNotice
            }
            keyboardGrid
            footer
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            model.onRequestFinish = finish
            model.start()
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(L10n.t("check.keyboard.hud_title"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text(model.globalHotkeyBlockingActive
                 ? L10n.t("check.keyboard.hint_block")
                 : L10n.t("check.keyboard.hint"))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            ProgressView(value: model.progress)
                .frame(width: 360)
            Text(L10n.t("check.keyboard.progress", model.testedKeyCodes.count, model.totalKeyCount))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            if model.globalHotkeyBlockingActive {
                Label(L10n.t("check.keyboard.block_on"), systemImage: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
    }

    private var accessibilityNotice: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L10n.t(model.hotkeyPermissionMessageKey, AppBrand.name, AppBrand.name))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(L10n.t("check.keyboard.open_a11y")) { model.openAccessibilitySettings() }
                Button(L10n.t("common.recheck")) { model.retryGlobalHotkeyBlocking() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.white)
        }
        .padding(14)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var keyboardGrid: some View {
        VStack(spacing: keySpacing) {
            ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(row) { key in
                        keyView(key)
                    }
                }
            }
        }
    }

    private func keyView(_ key: KeyDef) -> some View {
        let isPressed = model.pressedKeyCodes.contains(key.keyCode)
        let isStuck = model.stuckKeyCodes.contains(key.keyCode)
        let isTested = model.testedKeyCodes.contains(key.keyCode)

        let fill: Color = isStuck ? .red : isPressed ? .green : isTested ? Color.green.opacity(0.35) : Color.white.opacity(0.08)
        let border: Color = isStuck ? .red : isTested ? .green : Color.white.opacity(0.3)

        return Text(key.label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: keyUnit * key.widthUnits, height: keyUnit)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1.5))
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(L10n.t("check.keyboard.finish")) { finish() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("common.skip")) { skip() }
            if model.isComplete {
                Text(L10n.t("check.keyboard.all_done")).foregroundStyle(.green)
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private func finish() {
        // Release tap / kiosk before dismissing — onDisappear can race with fullscreen exit
        // and didBecomeActive would otherwise reinstall the event tap.
        model.stop()
        onFinish(model.buildResult())
    }

    private func skip() {
        model.stop()
        onFinish(CheckResult(
            id: "keyboard",
            title: L10n.t("check.keyboard.title"),
            status: .skipped,
            summary: L10n.t("check.keyboard.skip_summary")
        ))
    }
}
