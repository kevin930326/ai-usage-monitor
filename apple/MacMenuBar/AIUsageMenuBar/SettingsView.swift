import SwiftUI
import UniformTypeIdentifiers
import UsageKit
import UsageKitUI

/// 設定視窗（FR-35、ADR-0008 第 5 節）：選單列圖示樣式與顯示的額度、面板區塊的開關與排序。
/// 控制項自己畫（不用 AppKit 的 Toggle／Picker／List），ImageRenderer 才能截圖；鍵盤與 VoiceOver 仍可操作。
struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelSettings.self) private var settings
    /// ImageRenderer 畫不出 AppKit 的捲動視圖，截圖時關掉捲動
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { content }
                .frame(width: 460)
                .frame(minHeight: 520)
        } else {
            content.frame(width: 460)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            menuBarSection
            Divider()
            panelSection
        }
        .padding(22)
    }

    // MARK: - 選單列圖示

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("選單列圖示").font(.headline)
            HStack(spacing: 10) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    StyleTile(style: style, preview: previewContent, selected: settings.iconStyle == style) {
                        settings.iconStyle = style
                    }
                }
            }
            Text("雙圓環：外圈＝剩餘額度，內圈＝距離重置的剩餘時間。用得太快時右上角加小點、剩不到 20% 轉紅、資料過期轉灰並改為虛線。「只有 %」樣式以 ↑ 太快、! 剩不到 20%、– 過期區分。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("圖示顯示的額度").font(.subheadline.weight(.semibold)).padding(.top, 4)
            FlowChips(choices: windowChoices, selected: settings.iconWindow) { settings.iconWindow = $0 }
        }
    }

    /// 自動（剩最少的）＋目前快照中每個服務的每個可見額度
    private var windowChoices: [(MenuBarWindowChoice, String)] {
        var choices: [(MenuBarWindowChoice, String)] = [(.automatic, "自動（剩最少的）")]
        if let snapshot = store.snapshot {
            for key in snapshot.orderedProviderKeys {
                for window in snapshot.providers[key]?.visibleWindows ?? [] {
                    choices.append((.specific(provider: key, windowID: window.id), "\(ProviderInfo.displayName(key)) \(window.label)"))
                }
            }
        }
        if case .specific = settings.iconWindow, !choices.contains(where: { $0.0 == settings.iconWindow }) {
            // 指定的額度目前不存在（服務停用或改名）：圖示已退回剩餘最少的額度，這裡仍列出讓使用者看得到
            choices.append((settings.iconWindow, "\(settings.iconWindow.rawValue)（目前沒有資料）"))
        }
        return choices
    }

    private var previewContent: MenuBarIconContent? {
        guard let snapshot = store.snapshot, let item = snapshot.window(for: settings.iconWindow, at: store.now) else { return nil }
        return MenuBarIconContent(item: item, stale: snapshot.isStale(now: store.now), now: store.now,
                                  isLeast: settings.iconWindow == .automatic)
    }

    // MARK: - 面板區塊

    private var panelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("面板區塊").font(.headline)
                Text("拖曳調整順序").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢復預設") { settings.resetPanel() }
                    .buttonStyle(PanelPillButtonStyle())
            }
            let rows = settings.configurableSections
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.section) { index, row in
                    SectionRow(
                        section: row.section,
                        hasContextMenu: scrolls,
                        enabled: Binding(get: { row.enabled }, set: { settings.setEnabled($0, for: row.section) }),
                        canMoveUp: index > 0,
                        canMoveDown: index < rows.count - 1,
                        move: { offset in
                            settings.moveSections(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? index + 2 : index - 1)
                        }
                    )
                    .modifier(DragToReorder(enabled: scrolls, id: row.section.rawValue) { id in
                        guard let from = rows.firstIndex(where: { $0.section.rawValue == id }) else { return false }
                        settings.moveSections(fromOffsets: IndexSet(integer: from), toOffset: from < index ? index + 1 : index)
                        return true
                    })
                    if row.section == .quota {
                        SwitchRow(title: "預期進度標記", detail: "進度條上標出照時間比例應剩多少", isOn: Binding(
                            get: { settings.showsExpectedMarker }, set: { settings.showsExpectedMarker = $0 }
                        ))
                        .padding(.leading, 28)
                    }
                    if index < rows.count - 1 { Divider() }
                }
            }
            Text("之後加入的區塊（走勢、統計、服務狀態）會出現在這裡。卡片也可以在面板上直接收合。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 拖曳排序。截圖時關掉（拖放與右鍵選單由 AppKit 實作，ImageRenderer 畫不出來）。
private struct DragToReorder: ViewModifier {
    let enabled: Bool
    let id: String
    let drop: (String) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in items.first.map(drop) ?? false }
        } else {
            content
        }
    }
}

/// 圖示樣式的選項：預覽＋名稱。
private struct StyleTile: View {
    let style: MenuBarIconStyle
    let preview: MenuBarIconContent?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let preview {
                        MenuBarIconView(content: preview, style: style)
                    } else {
                        Image(systemName: "gauge.with.dots.needle.0percent")
                    }
                }
                .frame(height: 22)
                Text(style.title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 單選的膠囊按鈕，自動換行。
private struct FlowChips: View {
    let choices: [(MenuBarWindowChoice, String)]
    let selected: MenuBarWindowChoice
    let select: (MenuBarWindowChoice) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(choices, id: \.0) { choice, title in
                Button { select(choice) } label: {
                    Text(title)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(choice == selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(choice == selected ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == selected ? .isSelected : [])
            }
        }
    }
}

private struct SectionRow: View {
    let section: PanelSection
    var hasContextMenu = true
    @Binding var enabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            SwitchRow(title: section.title, detail: section.detail, isOn: $enabled)
        }
        .contentShape(Rectangle())
        .accessibilityAction(named: "上移") { if canMoveUp { move(-1) } }
        .accessibilityAction(named: "下移") { if canMoveDown { move(1) } }
        .contextMenu(hasContextMenu ? ContextMenu {
            Button("上移") { move(-1) }.disabled(!canMoveUp)
            Button("下移") { move(1) }.disabled(!canMoveDown)
        } : nil)
    }
}

/// 標題、說明與開關。開關自己畫，ImageRenderer 才能截圖。
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(DrawnSwitchStyle())
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.vertical, 8)
    }
}

struct DrawnSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Color.green : Color.primary.opacity(0.15))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(radius: 1).padding(2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "開啟" : "關閉")
    }
}

/// 簡單的自動換行排列。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let x = rows[rows.count - 1].items.isEmpty ? 0 : rows[rows.count - 1].width + spacing
            rows[rows.count - 1].items.append((index, x))
            rows[rows.count - 1].width = x + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
