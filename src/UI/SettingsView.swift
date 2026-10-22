import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("settings.theme.system")
        case .light: return L10n.t("settings.theme.light")
        case .dark: return L10n.t("settings.theme.dark")
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// System dark mode from AppleInterfaceStyle (ignores NSApp.appearance override).
    static var systemInterfaceIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Always a concrete scheme. On macOS, preferredColorScheme(nil) often sticks after light/dark.
    var resolvedColorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return Self.systemInterfaceIsDark ? .dark : .light
        }
    }

    /// Sync AppKit. For system: clear NSApp.appearance, set each window to effectiveAppearance
    /// (window.appearance = nil leaves the previous lock until focus changes).
    @MainActor
    func applyToApp() {
        switch self {
        case .light:
            Self.apply(NSAppearance(named: .aqua))
        case .dark:
            Self.apply(NSAppearance(named: .darkAqua))
        case .system:
            NSApp.appearance = nil
            Self.applyWindows(NSApp.effectiveAppearance)
        }
    }

    @MainActor
    private static func apply(_ appearance: NSAppearance?) {
        NSApp.appearance = appearance
        applyWindows(appearance)
    }

    @MainActor
    private static func applyWindows(_ appearance: NSAppearance?) {
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

/// Pins theme onto the host NSWindow; re-applies when the system appearance changes.
struct WindowAppearanceBridge: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        context.coordinator.attach(view: view, theme: theme)
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        context.coordinator.apply(theme: theme)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class TrackerView: NSView {
        var onMoveToWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }

    @MainActor
    final class Coordinator {
        private weak var view: TrackerView?
        private var theme: AppTheme = .system
        private var systemThemeObserver: NSObjectProtocol?

        func attach(view: TrackerView, theme: AppTheme) {
            self.view = view
            view.onMoveToWindow = { [weak self] in
                self?.apply(theme: self?.theme ?? .system)
            }
            if systemThemeObserver == nil {
                // Avoid KVO on effectiveAppearance (Swift 6 isolation).
                systemThemeObserver = DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // Notification can arrive before prefs update; apply on next turn.
                    DispatchQueue.main.async { self?.onSystemThemeChanged() }
                }
            }
            apply(theme: theme)
        }

        func apply(theme: AppTheme) {
            self.theme = theme
            theme.applyToApp()
            guard let window = view?.window else { return }
            switch theme {
            case .light:
                window.appearance = NSAppearance(named: .aqua)
            case .dark:
                window.appearance = NSAppearance(named: .darkAqua)
            case .system:
                window.appearance = NSApp.effectiveAppearance
            }
        }

        private func onSystemThemeChanged() {
            guard theme == .system else { return }
            apply(theme: .system)
        }
    }
}

struct SettingsView: View {
    @AppStorage("appTheme") private var themeRawValue = AppTheme.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue

    private var selectedTheme: Binding<AppTheme> {
        Binding {
            AppTheme(rawValue: themeRawValue) ?? .system
        } set: { newValue in
            themeRawValue = newValue.rawValue
        }
    }

    private var selectedLanguage: Binding<AppLanguage> {
        Binding {
            AppLanguage(stored: languageRawValue)
        } set: { newValue in
            languageRawValue = newValue.rawValue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                CheckHeader(
                    icon: "gearshape.fill",
                    title: L10n.t("settings.title"),
                    subtitle: L10n.t("settings.subtitle", AppBrand.name)
                )

                Card {
                    settingsRow(
                        icon: "globe",
                        title: L10n.t("settings.language"),
                        hint: L10n.t("settings.language.hint")
                    ) {
                        Picker(L10n.t("settings.language"), selection: selectedLanguage) {
                            ForEach(AppLanguage.choices) { lang in
                                Text(lang.title).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 220, alignment: .leading)
                        .padding(.top, DS.Spacing.xs)
                    }
                }

                Card {
                    settingsRow(
                        icon: "paintpalette.fill",
                        title: L10n.t("settings.theme"),
                        hint: L10n.t("settings.theme.hint")
                    ) {
                        Picker(L10n.t("settings.theme"), selection: selectedTheme) {
                            ForEach(AppTheme.allCases) { theme in
                                Label(theme.title, systemImage: theme.icon)
                                    .tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.top, DS.Spacing.xs)
                    }
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(L10n.t("settings.title"))
    }

    @ViewBuilder
    private func settingsRow<Content: View>(
        icon: String,
        title: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(title).font(DS.Font.bodyEmphasis)
                Text(hint)
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}
