import SwiftUI

/// Shared spacing, type, and colors. Prefer DS over local magic numbers.
enum DS {

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let pill: CGFloat = 999
    }

    enum Font {
        static let largeTitle = SwiftUI.Font.system(size: 26, weight: .bold)
        static let title = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let section = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
    }

    enum Color {
        static let cardBackground = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let windowBackground = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let hairline = SwiftUI.Color.primary.opacity(0.08)
        static let secondaryText = SwiftUI.Color.secondary
    }

    static func Divider() -> some View {
        Rectangle().fill(Color.hairline).frame(height: 1)
    }
}

// MARK: - CheckStatus visuals

extension CheckStatus {
    var symbolName: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .redFlag: return "exclamationmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .unsupported: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pass: return .green
        case .warning: return .orange
        case .redFlag: return .red
        case .skipped, .unsupported: return .secondary
        }
    }

    var label: String {
        switch self {
        case .pass: return L10n.t("status.pass")
        case .warning: return L10n.t("status.warning")
        case .redFlag: return L10n.t("status.redFlag")
        case .skipped: return L10n.t("status.skipped")
        case .unsupported: return L10n.t("status.unsupported")
        }
    }
}

// MARK: - Shared views

struct StatusDot: View {
    let status: CheckStatus
    var body: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: 13))
            .foregroundStyle(status.tint)
    }
}

struct CheckHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(title).font(DS.Font.title)
                Text(subtitle).font(DS.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InlineNotice: View {
    let icon: String
    let tint: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(DS.Font.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(tint.opacity(0.1)))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.section)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// Key/value row with a dotted leader; odd/even rows use different leader colors.
struct InfoRow: View {
    let key: String
    let value: String
    var mono: Bool = false
    /// Zero-based row index (zebra leader color).
    var index: Int = 0

    private var leaderColor: Color {
        index.isMultiple(of: 2)
            ? Color.primary.opacity(0.14)
            : Color.accentColor.opacity(0.45)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Text(key)
                .font(DS.Font.body)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            LeaderDots(color: leaderColor)
                .frame(maxWidth: .infinity)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            Text(value)
                .font(mono ? DS.Font.mono : DS.Font.body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .layoutPriority(1)
        }
        .padding(.vertical, 2)
    }
}

private struct LeaderDots: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            let step: CGFloat = 4
            var x: CGFloat = 1
            while x < size.width {
                let rect = CGRect(x: x, y: y - 0.5, width: 1.5, height: 1)
                context.fill(Path(ellipseIn: rect), with: .color(color))
                x += step
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Scrollable check detail pane with a nav title.
    func checkPane(_ title: String) -> some View {
        ScrollView {
            self
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(title)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            content
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.hairline))
    }
}
