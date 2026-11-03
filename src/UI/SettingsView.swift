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

    /// Toolbar cycle order: Auto → Light → Dark → Auto.
    var next: AppTheme {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    /// Whether macOS itself is in Dark mode (ignores our forced light/dark lock).
    static var systemInterfaceIsDark: Bool {
        // When we are not overriding NSApp.appearance, effectiveAppearance tracks the OS
        // and updates earlier than AppleInterfaceStyle UserDefaults after a theme switch.
        if NSApp.appearance == nil {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Always a concrete scheme. On macOS, preferredColorScheme(nil) often sticks after light/dark.
    var resolvedColorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return Self.systemInterfaceIsDark ? .dark : .light
        }
    }

    /// Sync AppKit with the selected theme.
    /// For `.system`: clear app/window appearance so they track the OS, then match
    /// `effectiveAppearance` once to force an immediate redraw after light/dark lock.
    @MainActor
    func applyToApp() {
        switch self {
        case .light:
            Self.apply(NSAppearance(named: .aqua))
        case .dark:
            Self.apply(NSAppearance(named: .darkAqua))
        case .system:
            NSApp.appearance = nil
            // Clear any previous light/dark pin first.
            Self.applyWindows(nil)
            // Then pin to the *current* effective appearance so the window redraws now.
            // SwiftUI still needs a body refresh (see RootView systemAppearanceRevision).
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

/// Pins theme onto the host NSWindow; notifies SwiftUI when the system appearance changes.
struct WindowAppearanceBridge: NSViewRepresentable {
    let theme: AppTheme
    /// Bump SwiftUI state so `preferredColorScheme` re-resolves after OS theme changes.
    var onSystemAppearanceChange: () -> Void = {}

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        context.coordinator.onSystemAppearanceChange = onSystemAppearanceChange
        context.coordinator.attach(view: view, theme: theme)
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        context.coordinator.onSystemAppearanceChange = onSystemAppearanceChange
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
        var onSystemAppearanceChange: () -> Void = {}

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
                    // Prefs often lag the notification by a turn (or two).
                    DispatchQueue.main.async {
                        DispatchQueue.main.async {
                            self?.onSystemThemeChanged()
                        }
                    }
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
                window.appearance = nil
                window.appearance = NSApp.effectiveAppearance
            }
        }

        private func onSystemThemeChanged() {
            guard theme == .system else { return }
            apply(theme: .system)
            onSystemAppearanceChange()
        }
    }
}

/// Toolbar control: click cycles Auto → Light → Dark; menu picks explicitly.
struct ThemeToolbarButton: View {
    @AppStorage("appTheme") private var themeRawValue = AppTheme.system.rawValue

    private var current: AppTheme {
        AppTheme(rawValue: themeRawValue) ?? .system
    }

    var body: some View {
        Menu {
            ForEach(AppTheme.allCases) { option in
                Button {
                    themeRawValue = option.rawValue
                } label: {
                    Label(option.title, systemImage: option == current ? "checkmark" : option.icon)
                }
            }
        } label: {
            Label(current.title, systemImage: current.icon)
        } primaryAction: {
            themeRawValue = current.next.rawValue
        }
        .help(L10n.t("toolbar.theme.help", current.title))
        .accessibilityLabel(L10n.t("settings.theme"))
        .accessibilityValue(current.title)
        .accessibilityHint(L10n.t("toolbar.theme.hint"))
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

                aboutCard
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(L10n.t("settings.title"))
    }

    private var aboutCard: some View {
        Card {
            settingsRow(
                icon: "info.circle.fill",
                title: L10n.t("settings.about.title"),
                hint: L10n.t("settings.about.blurb", AppBrand.name)
            ) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    aboutMetaRow(
                        label: L10n.t("settings.about.version"),
                        value: AppBrand.versionLabel
                    )
                    aboutMetaRow(
                        label: L10n.t("settings.about.repo"),
                        value: AppBrand.repositoryURL.absoluteString,
                        url: AppBrand.repositoryURL
                    )

                    Text(L10n.t("settings.about.dev_notes"))
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DS.Spacing.xs)

                    HStack(spacing: DS.Spacing.md) {
                        Link(destination: AppBrand.repositoryURL) {
                            Label(L10n.t("settings.about.open_repo"), systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        Link(destination: AppBrand.releasesURL) {
                            Label(L10n.t("settings.about.open_releases"), systemImage: "arrow.down.app")
                        }
                        .buttonStyle(.bordered)
                        Link(destination: AppBrand.issuesURL) {
                            Label(L10n.t("settings.about.open_issues"), systemImage: "exclamationmark.bubble")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, DS.Spacing.xs)
                }
                .padding(.top, DS.Spacing.xs)
            }
        }
    }

    private func aboutMetaRow(label: String, value: String, url: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            if let url {
                Link(value, destination: url)
                    .font(DS.Font.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(value)
                    .font(DS.Font.mono)
            }
            Spacer(minLength: 0)
        }
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
