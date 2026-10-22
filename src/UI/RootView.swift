import AppKit
import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @AppStorage("appTheme") private var themeRawValue = AppTheme.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue
    @State private var testWindow: NSWindow?
    @State private var enteredFullScreenForTest = false
    @State private var screenTestWindow: NSWindow?

    private var preferredScheme: ColorScheme? {
        (AppTheme(rawValue: themeRawValue) ?? .system).colorScheme
    }

    private var appLocale: Locale {
        AppLanguage(stored: languageRawValue).locale
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
            } detail: {
                DetailRouter()
            }
            .id(languageRawValue)
            .disabled(model.fullscreenTest != nil)

            if let test = model.fullscreenTest, test.id == "keyboard" {
                fullscreenOverlay(test)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .environmentObject(model)
        .environment(\.locale, appLocale)
        .preferredColorScheme(preferredScheme)
        .animation(.easeInOut(duration: 0.2), value: model.fullscreenTest?.id)
        .task { await model.scanIfNeeded() }
        .onChange(of: languageRawValue) { _, _ in
            Task { await model.rescan() }
        }
        .onChange(of: model.fullscreenTest?.id) { _, newID in
            switch newID {
            case "screen":
                // 屏幕测试不复用主窗口的全屏状态：单独开一个无边框、覆盖全屏的测试窗口，
                // 这样无论主窗口当前是不是全屏，测试区域都保证覆盖整个屏幕。
                exitTestFullScreenIfNeeded()
                presentScreenTestWindow()
            case "keyboard":
                dismissScreenTestWindow()
                enterTestFullScreenIfNeeded()
            case nil:
                exitTestFullScreenIfNeeded()
                dismissScreenTestWindow()
            default:
                break
            }
        }
    }

    /// 键盘/屏幕测试使用系统原生全屏，真正覆盖整个屏幕（含菜单栏与 Dock 区域）。
    @MainActor
    private func enterTestFullScreenIfNeeded() {
        guard !enteredFullScreenForTest else { return }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.contentView != nil }) else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        testWindow = window
        enteredFullScreenForTest = true
        window.toggleFullScreen(nil)
    }

    @MainActor
    private func exitTestFullScreenIfNeeded() {
        guard enteredFullScreenForTest, let window = testWindow else { return }
        enteredFullScreenForTest = false
        testWindow = nil
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - 屏幕测试：独立的无边框全屏窗口

    @MainActor
    private func presentScreenTestWindow() {
        guard screenTestWindow == nil else { return }
        guard let screen = NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first else { return }

        let window = BorderlessTestWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // screenSaver 层级可以盖住菜单栏、Dock 和其它 App 窗口，保证整块屏幕都是测试区域。
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]

        let appModel = model
        window.contentView = NSHostingView(rootView: ScreenCheckView { result in
            appModel.recordTest(result)
            appModel.fullscreenTest = nil
        })

        screenTestWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func dismissScreenTestWindow() {
        guard let window = screenTestWindow else { return }
        screenTestWindow = nil
        window.orderOut(nil)
        window.close()
        NSApp.windows.first(where: { $0 !== window && $0.contentView != nil })?
            .makeKeyAndOrderFront(nil)
    }

    @ViewBuilder
    private func fullscreenOverlay(_ test: FullscreenTest) -> some View {
        switch test {
        case .keyboard:
            KeyboardCheckView { result in
                model.recordTest(result)
                model.fullscreenTest = nil
            }
        case .screen:
            EmptyView() // 屏幕测试走独立的 BorderlessTestWindow
        }
    }
}

/// 无边框窗口默认不能成为 key window；重写后才能接收键盘事件。
private final class BorderlessTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
