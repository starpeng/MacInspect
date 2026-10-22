import SwiftUI
import AppKit

/// Detail pane router.
struct DetailRouter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView()
        case .specs:
            SpecsView()
        case .keyboard:
            FullscreenLaunchPane(item: .keyboard, test: .keyboard,
                icon: "keyboard.fill", title: L10n.t("check.keyboard.title"),
                subtitle: L10n.t("check.keyboard.subtitle"))
        case .screen:
            FullscreenLaunchPane(item: .screen, test: .screen,
                icon: "display", title: L10n.t("check.screen.title"),
                subtitle: L10n.t("check.screen.subtitle"))
        case .audio:
            AudioCheckView { model.recordTest($0) }
        case .microphone:
            MicrophoneCheckView { model.recordTest($0) }
        case .camera:
            CameraCheckView { model.recordTest($0) }
        case .touchID:
            TouchIDCheckView { model.recordTest($0) }
        case .trackpad:
            TrackpadCheckView { model.recordTest($0) }
        case .performance:
            PerformanceCheckView { model.recordTest($0) }
        case .diskSpeed:
            DiskSpeedCheckView { model.recordTest($0) }
        case .portsLive:
            PortLiveCheckView { model.recordTest($0) }
        case .aiModels:
            AIModelsView()
        case .settings:
            SettingsView()
        default:
            CategoryDetailView(item: model.selection ?? .overview)
        }
    }
}

// MARK: - Specs

struct SpecsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                if let p = model.profile {
                    basicInfoCard(p)
                    graphicsCard(p)
                    systemCard(p)
                    warrantyCard(p)
                } else {
                    ProgressView(L10n.t("detail.reading_specs"))
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(L10n.t("sidebar.specs"))
    }

    // Basics
    private func basicInfoCard(_ p: DeviceProfile) -> some View {
        Card {
            cardHeader(icon: "laptopcomputer", title: L10n.t("specs.basic"))
            KeyValueList {
                KVRow(icon: "macbook", key: L10n.t("specs.model"), value: p.marketingName)
                KVRow(icon: "barcode", key: L10n.t("specs.serial"), value: p.serialNumber, mono: true, copyable: true)
                KVRow(icon: "tag", key: L10n.t("specs.model_id"), value: p.modelIdentifier, mono: true)
                KVRow(icon: "cpu", key: L10n.t("specs.chip"), value: p.chip)
                KVRow(icon: "memorychip", key: L10n.t("specs.memory"), value: p.memory)
                KVRow(icon: "square.stack.3d.up", key: L10n.t("specs.arch"), value: p.architecture, last: true)
            }
        }
    }

    private func graphicsCard(_ p: DeviceProfile) -> some View {
        Card {
            cardHeader(icon: "rectangle.on.rectangle.angled", title: L10n.t("specs.graphics"))
            if p.graphics.isEmpty {
                Text(L10n.t("specs.gpu.none"))
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
            } else {
                KeyValueList {
                    ForEach(Array(p.graphics.enumerated()), id: \.offset) { index, gpu in
                        KVRow(
                            icon: "gpu",
                            key: gpu.name,
                            value: gpu.detail,
                            last: index == p.graphics.count - 1
                        )
                    }
                }
            }
            InlineNotice(icon: "info.circle", tint: .secondary, text: L10n.t("specs.gpu.notice"))
        }
    }

    // System
    private func systemCard(_ p: DeviceProfile) -> some View {
        Card {
            cardHeader(icon: "gearshape", title: L10n.t("specs.system"))
            KeyValueList {
                KVRow(icon: "apple.logo", key: L10n.t("specs.os"), value: p.macOSVersion, last: true)
            }
        }
    }

    // Purchase / warranty
    private func warrantyCard(_ p: DeviceProfile) -> some View {
        let lock = model.result(id: "management.activationLock")
        return Card {
            cardHeader(icon: "checkmark.seal", title: L10n.t("specs.warranty"))
            KeyValueList {
                KVRow(icon: "calendar", key: L10n.t("specs.year"), value: p.modelYear.isEmpty ? L10n.t("common.unknown") : p.modelYear)
                KVRow(icon: "clock.arrow.circlepath", key: L10n.t("specs.age"), value: ageText(p.modelYear))
                KVRow(icon: "hammer", key: L10n.t("specs.produced"), value: p.productionDate)
                KVRow(icon: "lock.shield",
                      key: L10n.t("specs.activation_lock"),
                      value: lock?.summary ?? L10n.t("specs.see_security"),
                      valueTint: lock?.status.tint,
                      last: true)
            }

            InlineNotice(icon: "info.circle", tint: .secondary,
                text: L10n.t("specs.warranty_notice"))

            HStack(spacing: DS.Spacing.md) {
                Button {
                    if let url = URL(string: "https://checkcoverage.apple.com/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L10n.t("specs.check_coverage"), systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.serialNumber, forType: .string)
                } label: {
                    Label(L10n.t("specs.copy_serial"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(p.serialNumber.isEmpty)
            }
        }
    }

    private func cardHeader(icon: String, title: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(.tint).font(.system(size: 13, weight: .semibold))
            SectionLabel(text: title)
            Spacer()
        }
    }

    private func ageText(_ yearStr: String) -> String {
        guard let year = Int(yearStr) else { return L10n.t("common.unknown") }
        let now = Calendar.current.component(.year, from: Date())
        let age = now - year
        if age <= 0 { return L10n.t("specs.age.current") }
        return L10n.t("specs.age.years", age)
    }
}

struct KeyValueList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
    }
}

struct KVRow: View {
    let icon: String
    let key: String
    let value: String
    var mono: Bool = false
    var copyable: Bool = false
    var valueTint: Color? = nil
    var last: Bool = false

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(key).font(DS.Font.body).foregroundStyle(.secondary)
                Spacer(minLength: DS.Spacing.lg)
                Text(value)
                    .font(mono ? DS.Font.mono : DS.Font.body)
                    .foregroundStyle(valueTint ?? .primary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if copyable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("detail.copy"))
                }
            }
            .padding(.vertical, DS.Spacing.sm)
            if !last { DS.Divider() }
        }
    }
}

// MARK: - Category detail

struct CategoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                let results = model.results(for: item)
                if results.isEmpty {
                    if model.isScanning {
                        ProgressView(L10n.t("detail.scanning"))
                    } else {
                        InlineNotice(icon: "minus.circle", tint: .secondary, text: L10n.t("detail.empty"))
                    }
                } else {
                    ForEach(results) { result in
                        resultCard(result)
                    }
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(item.title)
    }

    private func resultCard(_ result: CheckResult) -> some View {
        Card {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                Image(systemName: result.status.symbolName)
                    .font(.system(size: 20)).foregroundStyle(result.status.tint)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack(spacing: DS.Spacing.sm) {
                        Text(result.title).font(DS.Font.bodyEmphasis)
                        StatusPill(status: result.status)
                    }
                    Text(result.summary).font(DS.Font.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if let headline = result.isRedFlagHeadline {
                Text(headline)
                    .font(DS.Font.body)
                    .padding(DS.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(Color.red.opacity(0.1)))
            }
            if !result.rawDetails.isEmpty {
                DS.Divider()
                let pairs = result.rawDetails.sorted(by: { $0.key < $1.key })
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(Array(pairs.enumerated()), id: \.element.key) { index, pair in
                        InfoRow(key: pair.key, value: pair.value, mono: true, index: index)
                    }
                }
            }
        }
    }
}

struct StatusPill: View {
    let status: CheckStatus
    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(status.tint.opacity(0.15)))
            .foregroundStyle(status.tint)
    }
}

// MARK: - Fullscreen test launch

struct FullscreenLaunchPane: View {
    @EnvironmentObject private var model: AppModel
    let item: SidebarItem
    let test: FullscreenTest
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                CheckHeader(icon: icon, title: title, subtitle: subtitle)

                if let result = model.result(id: item.resultIDs.first ?? "") {
                    Card {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: result.status.symbolName)
                                .font(.system(size: 20)).foregroundStyle(result.status.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: DS.Spacing.sm) {
                                    Text(L10n.t("detail.last_result")).font(DS.Font.bodyEmphasis)
                                    StatusPill(status: result.status)
                                }
                                Text(result.summary).font(DS.Font.body).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                HStack(spacing: DS.Spacing.md) {
                    Button {
                        model.fullscreenTest = test
                    } label: {
                        Label(model.result(id: item.resultIDs.first ?? "") == nil ? L10n.t("detail.start_test") : L10n.t("detail.retest"),
                              systemImage: "play.fill")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(L10n.t("common.skip")) {
                        skipItem()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                InlineNotice(icon: "info.circle", tint: .secondary,
                    text: item == .keyboard
                        ? L10n.t("detail.fullscreen.kb_hint")
                        : L10n.t("detail.fullscreen.screen_hint"))
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(title)
    }

    private func skipItem() {
        let id = item.resultIDs.first ?? test.id
        let summaryKey = item == .keyboard ? "check.keyboard.skip_summary" : "check.screen.skip_summary"
        model.recordTest(CheckResult(
            id: id,
            title: title,
            status: .skipped,
            summary: L10n.t(summaryKey)
        ))
    }
}
