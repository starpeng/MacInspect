import SwiftUI

/// Sidebar: overview, system checks, hardware tests; status dots per row.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Stack list + footer so rows don't paint through a transparent inset.
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                row(.overview)
                row(.settings)

                Section(L10n.t("sidebar.section.system")) {
                    ForEach(SidebarItem.autoCategories) { row($0) }
                    row(.aiModels)
                }

                Section(L10n.t("sidebar.section.hardware")) {
                    ForEach(SidebarItem.interactiveTests) { row($0) }
                }
            }
            .listStyle(.sidebar)

            rescanBar
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                Spacer()
                if let status = model.status(for: item) {
                    StatusDot(status: status)
                } else if item.isInteractive {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: item.icon)
        }
        .tag(item)
    }

    private var rescanBar: some View {
        VStack(spacing: 0) {
            DS.Divider()
            HStack(spacing: DS.Spacing.sm) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("sidebar.scanning")).font(DS.Font.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.system(size: 12))
                    Text(L10n.t("sidebar.scan_done")).font(DS.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
                .help(L10n.t("sidebar.rescan_help"))
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
        .background {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
