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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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
