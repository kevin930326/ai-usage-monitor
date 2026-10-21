import SwiftUI
import UsageKit
import UsageKitUI

/// 點開選單列後的面板（FR-22）：所有額度、進度條、重置倒數、更新時間。
struct PanelView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let snapshot = store.snapshot {
                let stale = snapshot.isStale(now: store.now)
                if let item = snapshot.tightestWindow(at: store.now) {
                    TightestRow(item: item, stale: stale, now: store.now)
                }
                Divider()
                ForEach(snapshot.orderedProviderKeys, id: \.self) { key in
                    if let provider = snapshot.providers[key] {
                        ProviderBlock(key: key, provider: provider, stale: stale, now: store.now)
                    }
                }
                Divider()
                UpdatedText(updatedAt: snapshot.updatedAt, stale: stale)
                    .font(.caption)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(UsageColors.notice)
                Text(store.locator.usageFile.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("AI 用量").font(.title3.weight(.semibold))
            Spacer()
            Button("重新讀取", systemImage: "arrow.clockwise") { store.reload() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            Button("結束", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

/// 最吃緊的一項大字顯示（FR-15 的 Mac 版）。
private struct TightestRow: View {
    let item: ProviderWindow
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(Int(item.window.effectiveRemainingPct(at: now).rounded()))%")
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(stale ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ProviderInfo.displayName(item.provider)) · \(item.window.label)")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 4) {
                    Text("剩餘 ·")
                    ResetText(window: item.window, now: now)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
