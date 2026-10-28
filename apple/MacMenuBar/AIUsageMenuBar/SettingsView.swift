import SwiftUI
import UniformTypeIdentifiers
import UsageKit
import UsageKitUI

/// 設定視窗（FR-35、FR-37、FR-19、FR-47、FR-51，ADR-0008 第 5 節）：登入時自動打開、外觀、選單列圖示樣式與顯示的額度、面板區塊的開關與排序、歷史資料、通知、快捷鍵。
/// 控制項自己畫（不用 AppKit 的 Toggle／Picker／List），ImageRenderer 才能截圖；鍵盤與 VoiceOver 仍可操作。
struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelSettings.self) private var settings
    @Environment(HistoryStore.self) private var history
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
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
            LoginItemSection()
            Divider()
            CollectorSettingsSection(interactive: scrolls)
            Divider()
            AppearanceSettingsSection()
            Divider()
            menuBarSection
            Divider()
            NotchSettingsSection()
            Divider()
            panelSection
            Divider()
            HistorySettingsSection(store: history, interactive: scrolls)
            Divider()
            NotificationSettingsSection(interactive: scrolls)
            Divider()
            HotKeySettingsSection(interactive: scrolls)
        }
        .padding(22)
        // 換外觀時與面板相同的過渡；減少動態效果時直接換（FR-51）
        .animation(scrolls && !reduceMotion ? PanelTiming.colorScheme : nil, value: colorScheme)
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
            Text("卡片也可以在面板上直接收合。服務狀態在都正常時只有一行。")
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
struct FlowChips<Choice: Hashable>: View {
    let choices: [(Choice, String)]
    let selected: Choice
    let select: (Choice) -> Void

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

/// 歷史資料（FR-37、ADR-0009 第 5 節）：保留期間、匯出 CSV、清除歷史、清除並重新掃描。
/// 每次打開設定視窗時另開短暫的連線讀取資訊，寫入（清除、縮短保留期間）由 App 直接執行。
private struct HistorySettingsSection: View {
    @Environment(PanelSettings.self) private var settings
    let store: HistoryStore
    /// 截圖時不讀資料庫以外的東西、不開對話框
    var interactive = true

    @State private var info: HistoryStore.Info?
    @State private var pendingRetention: Int?
    @State private var confirmClear: Bool = false
    @State private var confirmRescan: Bool = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("歷史資料").font(.headline)
            Text("額度歷史存在這台 Mac 的 history.sqlite3（收集器每 5 分鐘寫入），不會上傳。面板的走勢、額度消耗與預測都用它。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = statusNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(UsageColors.notice)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("保留期間").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(HistoryStore.retentionChoices, id: \.days) { choice in
                    let selected = (info?.retentionDays ?? HistoryStore.defaultRetentionDays) == choice.days
                    Button { choose(choice.days) } label: {
                        Text(choice.title)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(!writable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("預設 1 年；35 天前的資料降為每小時一筆。縮短時會立即刪除超出的資料。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let info, info.sampleCount > 0 {
                Text(summary(info)).font(.caption).foregroundStyle(.secondary)
            }
            if let info, let size = info.size {
                Text(sizeSummary(size, retentionDays: info.retentionDays))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("匯出額度 CSV…") { export(.quota) }
                    .buttonStyle(PanelPillButtonStyle())
                    .disabled(!(info?.status.canRead ?? false))
                Button("匯出 Token CSV…") { export(.tokens) }
                    .buttonStyle(PanelPillButtonStyle())
                    .disabled(!(info?.status.canRead ?? false))
                    .help("每日 Token：日期（本機時間）、服務、模型，四種 Token 與推理分開，以及任務數與任務秒數")
            }
            HStack(spacing: 8) {
                Button("清除歷史…") { confirmClear = true }
                    .buttonStyle(PanelPillButtonStyle())
                    .disabled(!writable)
                Button("清除並重新掃描…") { confirmRescan = true }
                    .buttonStyle(PanelPillButtonStyle())
                    .disabled(!writable)
            }
            Text("「清除並重新掃描」另外清除對話紀錄的掃描進度，讓 Token 統計從現有的對話紀錄重建；額度歷史沒有來源可以重建。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if interactive { refresh() } else { info = store.info() } }
        .confirmationDialog("縮短保留期間？", isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button("縮短並刪除", role: .destructive) {
                if let days = pendingRetention { apply(days) }
            }
        } message: {
            Text("超出新保留期間的額度歷史會立即刪除，無法復原。")
        }
        .confirmationDialog("清除額度歷史？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { clear(rescan: false) }
        } message: {
            Text("刪除所有額度歷史與每週備份，面板的走勢與額度消耗會從頭開始收集。無法復原。")
        }
        .confirmationDialog("清除並重新掃描？", isPresented: $confirmRescan) {
            Button("清除並重新掃描", role: .destructive) { clear(rescan: true) }
        } message: {
            Text("刪除所有歷史、每週備份與掃描進度。無法復原。")
        }
    }

    private var writable: Bool { info?.status == .ready }

    private var statusNote: String? {
        switch info?.status {
        case .missing: "還沒有歷史資料：收集器更新後下一次執行會開始寫入（若一直沒有，請重新執行 collector/scripts/install-launchd.sh）"
        case .olderSchema: "收集器的版本較舊，請重新執行 collector/scripts/install-launchd.sh"
        case .newerSchema: "歷史資料的版本比 App 新：可以查看，但不能清除或修改，請更新 App"
        case .failed: "無法讀取 history.sqlite3（檔案可能已損毀）"
        default: nil
        }
    }

    private func summary(_ info: HistoryStore.Info) -> String {
        var text = "目前 \(info.sampleCount.formatted()) 筆"
        if let oldest = info.oldest {
            text += "，最早 " + oldest.formatted(.dateTime.year().month().day())
        }
        return text
    }

    /// 資料庫大小與預估（ADR-0014）：保留期間內會穩定下來的大小，永久保留時改說每年增加多少；
    /// 有保留期間時仍會一直增加的部分（個人紀錄、舊版收集器的去重紀錄）每年超過 1 MB 才另外說
    private func sizeSummary(_ size: HistorySize, retentionDays: Int) -> String {
        let text = "資料庫 " + Self.bytes(size.fileBytes)
        guard let estimate = size.estimate(retentionDays: retentionDays) else {
            return text + "，資料滿 \(HistorySize.minimumDays) 天後估算成長"
        }
        guard let steady = estimate.steady else {
            return text + "，依最近的使用量，永久保留時每年約增加 " + Self.bytes(estimate.perYear)
        }
        let title = HistoryStore.retentionChoices.first { $0.days == retentionDays }?.title ?? "\(retentionDays) 天"
        var result = text + "，依最近的使用量，保留 \(title)時約維持在 " + Self.bytes(steady)
        if estimate.perYear >= 1_000_000 {
            result += "，之後每年約增加 " + Self.bytes(estimate.perYear)
        }
        return result
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private func refresh() {
        let store = store
        Task.detached {
            let info = store.info()
            await MainActor.run { self.info = info }
        }
    }

    private func choose(_ days: Int) {
        let current = info?.retentionDays ?? HistoryStore.defaultRetentionDays
        guard days != current else { return }
        let shorter = days > 0 && (current == 0 || days < current)
        if shorter { pendingRetention = days } else { apply(days) }
    }

    private func apply(_ days: Int) {
        pendingRetention = nil
        run(done: "已更新保留期間") { try store.setRetention(days: days) }
    }

    private func clear(rescan: Bool) {
        run(done: rescan ? "已清除歷史與掃描進度" : "已清除歷史") { try store.clear(rescan: rescan) }
    }

    private func run(done: String, _ action: @escaping @Sendable () throws -> Void) {
        let store = store
        Task.detached {
            let result: String
            do {
                try action()
                result = done
            } catch HistoryStore.WriteError.copiesRemain {
                result = "已清除歷史，但每週備份或保留的舊檔刪不掉：請手動刪除 history.sqlite3 旁的 backups 資料夾與 history.corrupt-* 檔案"
            } catch HistoryStore.WriteError.unsupportedSchema {
                result = "歷史資料的版本不符，沒有變更"
            } catch {
                result = "無法寫入 history.sqlite3，請稍後再試（收集器可能正在寫入）"
            }
            let info = store.info()
            await MainActor.run {
                self.message = result
                self.info = info
                // 面板開著時立即反映
                HistoryStore.shared.reload()
            }
        }
    }

    private enum Export {
        case quota, tokens
    }

    private func export(_ kind: Export) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let date = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = kind == .quota ? "ai-usage-history-\(date).csv" : "ai-usage-tokens-\(date).csv"
        panel.canCreateDirectories = true
        // runModal 的對話框是獨立視窗、不是設定視窗的 sheet，不會繼承設定視窗的外觀（總檢查 F-05）
        panel.appearance = settings.appearance.nsAppearance
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let csv = try kind == .quota ? store.exportCSV() : store.exportTokenCSV()
            try Data(csv.utf8).write(to: url, options: .atomic)
            message = "已匯出到 \(url.lastPathComponent)"
        } catch HistoryStore.WriteError.missing where kind == .tokens {
            message = "還沒有 Token 統計可以匯出"
        } catch {
            message = "匯出失敗"
        }
    }
}

/// 設定「外觀」（FR-51）。獨立出來，README 的截圖可以只畫這一段（DebugTools）
struct AppearanceSettingsSection: View {
    @Environment(PanelSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("外觀").font(.headline)
            FlowChips(choices: AppearanceChoice.allCases.map { ($0, $0.title) }, selected: settings.appearance) {
                settings.appearance = $0
            }
            Text("套用到面板、設定、完整統計與設定精靈。選單列圖示跟隨選單列本身的深淺色，不受這個設定影響。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
