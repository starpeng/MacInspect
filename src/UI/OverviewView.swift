import SwiftUI

/// 概览页：小白验机结论卡片 + 机器档案 + 红旗 + 分类一览。
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                deviceHeader
                if !model.isScanning { verdictCard }
                if !model.report.redFlags.isEmpty { redFlagSection }
                categorySummary
                testSummary
                footer
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(L10n.t("overview.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        ReportExporter.export(profile: model.profile, report: model.report, format: .png)
                    } label: { Label(L10n.t("report.export_png"), systemImage: "photo") }
                    Button {
                        ReportExporter.export(profile: model.profile, report: model.report, format: .pdf)
                    } label: { Label(L10n.t("report.export_pdf"), systemImage: "doc.richtext") }
                } label: {
                    Label(L10n.t("common.export"), systemImage: "square.and.arrow.up")
                }
                .disabled(model.isScanning)
            }
        }
    }

    // MARK: - 小白模式：验机结论卡片

    private var verdictCard: some View {
        let verdict = Self.verdict(for: model)
        return Card {
            HStack(alignment: .top, spacing: DS.Spacing.lg) {
                Image(systemName: verdict.symbol)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(verdict.tint)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(spacing: DS.Spacing.sm) {
                        Text(L10n.t("overview.verdict.title")).font(DS.Font.title)
                        Text(verdict.badge)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(verdict.tint.opacity(0.15)))
                            .foregroundStyle(verdict.tint)
                    }
                    Text(verdict.headline)
                        .font(DS.Font.bodyEmphasis)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verdict.detail)
                        .font(DS.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DS.Spacing.lg) {
                        metric(L10n.t("overview.verdict.metric.red"), "\(model.report.redFlags.count)",
                               tint: model.report.redFlags.isEmpty ? .secondary : .red)
                        metric(L10n.t("overview.verdict.metric.warn"), "\(warningCount)",
                               tint: warningCount == 0 ? .secondary : .orange)
                        metric(L10n.t("overview.verdict.metric.tests"),
                               "\(model.completedTestCount)/\(SidebarItem.interactiveTests.count)",
                               tint: .secondary)
                        metric(L10n.t("overview.verdict.metric.score"), "\(model.report.score)", tint: scoreColor)
                    }
                    .padding(.top, DS.Spacing.xs)

                    Text(L10n.t("overview.verdict.code", ReportFingerprint.make(profile: model.profile, report: model.report)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var warningCount: Int {
        model.report.results.filter { $0.status == .warning }.count
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Font.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
        }
    }

    private struct VerdictInfo {
        let badge: String
        let headline: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    private static func verdict(for model: AppModel) -> VerdictInfo {
        let red = model.report.redFlags.count
        let warn = model.report.results.filter { $0.status == .warning }.count
        let testsLeft = SidebarItem.interactiveTests.count - model.completedTestCount

        if red > 0 {
            return VerdictInfo(
                badge: L10n.t("overview.verdict.badge.critical"),
                headline: L10n.t("overview.verdict.head.critical", red),
                detail: L10n.t("overview.verdict.detail.critical"),
                symbol: "xmark.octagon.fill",
                tint: .red
            )
        }
        if warn > 0 || model.report.score < 90 {
            return VerdictInfo(
                badge: L10n.t("overview.verdict.badge.caution"),
                headline: warn > 0
                    ? L10n.t("overview.verdict.head.caution_warn", warn)
                    : L10n.t("overview.verdict.head.caution_score"),
                detail: testsLeft > 0
                    ? L10n.t("overview.verdict.detail.caution_pending", testsLeft)
                    : L10n.t("overview.verdict.detail.caution_done"),
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if testsLeft > 0 {
            return VerdictInfo(
                badge: L10n.t("overview.verdict.badge.pending"),
                headline: L10n.t("overview.verdict.head.pending"),
                detail: L10n.t("overview.verdict.detail.pending", testsLeft),
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        }
        return VerdictInfo(
            badge: L10n.t("overview.verdict.badge.good"),
            headline: L10n.t("overview.verdict.head.good"),
            detail: L10n.t("overview.verdict.detail.good"),
            symbol: "checkmark.seal.fill",
            tint: .green
        )
    }

    // MARK: - 机器档案头部

    private var deviceHeader: some View {
        Card {
            HStack(alignment: .top, spacing: DS.Spacing.lg) {
                Image(systemName: deviceSymbol)
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(model.profile?.marketingName ?? L10n.t("overview.identifying"))
                        .font(DS.Font.largeTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if let p = model.profile {
                        Text("\(p.chip) · \(p.memory) · \(p.macOSVersion)")
                            .font(DS.Font.body).foregroundStyle(.secondary)
                        HStack(spacing: DS.Spacing.sm) {
                            metaChip(icon: "barcode",
                                     text: p.serialNumber.isEmpty ? L10n.t("overview.serial_unknown") : p.serialNumber)
                            metaChip(icon: "cpu", text: p.architecture)
                            if !p.modelYear.isEmpty {
                                metaChip(icon: "calendar", text: L10n.t("overview.year_format", p.modelYear))
                            }
                        }
                    }
                }
                Spacer(minLength: DS.Spacing.md)
                scoreBadge
            }
        }
    }

    private func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(DS.Font.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    private var scoreBadge: some View {
        VStack(spacing: 2) {
            Text("\(model.report.score)")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(scoreColor)
                .contentTransition(.numericText())
            Text(L10n.t("report.score")).font(DS.Font.caption).foregroundStyle(.secondary)
        }
    }

    private var scoreColor: Color {
        if !model.report.redFlags.isEmpty || model.report.score < 60 { return .red }
        if model.report.score < 90 { return .orange }
        return .green
    }

    private var deviceSymbol: String {
        let name = model.profile?.marketingName ?? ""
        if name.contains("mini") || name.contains("Mac Pro") || name.contains("Studio") { return "macstudio.fill" }
        if name.contains("iMac") { return "desktopcomputer" }
        if name.contains("Air") { return "macbook" }
        return "macbook"
    }

    // MARK: - 红旗区

    private var redFlagSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Label(L10n.t("overview.red_flags.title"), systemImage: "exclamationmark.octagon.fill")
                .font(DS.Font.title).foregroundStyle(.red)
            ForEach(model.report.redFlags) { flag in
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Text(flag.isRedFlagHeadline ?? flag.summary)
                        .font(DS.Font.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(Color.red.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(Color.red.opacity(0.25)))
            }
        }
    }

    // MARK: - 分类状态一览

    private var categorySummary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L10n.t("overview.section.system"))
            Card {
                ForEach(Array(SidebarItem.autoCategories.enumerated()), id: \.element) { index, item in
                    summaryRow(item)
                    if index < SidebarItem.autoCategories.count - 1 { DS.Divider() }
                }
            }
        }
    }

    private var testSummary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                SectionLabel(text: L10n.t("overview.section.hardware"))
                Spacer()
                Text(L10n.t("overview.tests_progress",
                            model.completedTestCount,
                            SidebarItem.interactiveTests.count))
                    .font(DS.Font.caption).foregroundStyle(.secondary)
            }
            Card {
                ForEach(Array(SidebarItem.interactiveTests.enumerated()), id: \.element) { index, item in
                    summaryRow(item)
                    if index < SidebarItem.interactiveTests.count - 1 { DS.Divider() }
                }
            }
        }
    }

    private func summaryRow(_ item: SidebarItem) -> some View {
        Button {
            model.selection = item
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: item.icon).frame(width: 22).foregroundStyle(.tint)
                Text(item.title).font(DS.Font.bodyEmphasis)
                Spacer()
                if let status = model.status(for: item) {
                    Text(model.results(for: item).first?.summary ?? status.label)
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 320, alignment: .trailing)
                    StatusDot(status: status)
                } else {
                    Text(item.isInteractive ? L10n.t("overview.untested") : "—")
                        .font(DS.Font.caption).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            DS.Divider()
            Text(L10n.t("overview.time_version",
                        model.generatedAt.formatted(date: .abbreviated, time: .shortened),
                        AppBrand.name,
                        model.report.appVersion))
            Text(L10n.t("privacy.footer"))
        }
        .font(DS.Font.caption).foregroundStyle(.secondary)
        .padding(.top, DS.Spacing.sm)
    }
}
