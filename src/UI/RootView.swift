import AppKit
import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @AppStorage("appTheme") private var themeRawValue = AppTheme.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue
    @State private var testWindow: NSWindow?
    @State private var enteredFullScreenForTest = false
    @State private var screenTestWindow: NSWindow?

    private var currentTheme: AppTheme {
        AppTheme(rawValue: themeRawValue) ?? .system
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
        .preferredColorScheme(currentTheme.resolvedColorScheme)
        .background(WindowAppearanceBridge(theme: currentTheme).frame(width: 0, height: 0))
        .environmentObject(model)
        .environment(\.locale, appLocale)
        .animation(.easeInOut(duration: 0.2), value: model.fullscreenTest?.id)
        .task { await model.scanIfNeeded() }
        .onChange(of: languageRawValue) { _, _ in
            Task { await model.rescan() }
        }
        .onChange(of: model.fullscreenTest?.id) { _, newID in
            switch newID {
            case "screen":
                // Own borderless window so coverage isn't tied to main-window fullscreen.
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

    /// Native fullscreen for keyboard test (covers menu bar / Dock).
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

    // MARK: - Screen test (borderless fullscreen window)

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
        // Above menu bar / Dock / other apps.
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
            EmptyView() // Screen test uses BorderlessTestWindow
        }
    }
}

/// Borderless NSWindow must opt in to key/main to get keyboard events.
private final class BorderlessTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
