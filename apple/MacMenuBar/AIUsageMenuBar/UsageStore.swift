import Foundation
import Observation
import UsageKit
import WidgetKit

/// 讀取並監看本機 `usage.json`（FR-20）。收集器以「寫暫存檔再改名」更新，
/// 監看檔案本身會在改名後失效，所以監看所在資料夾。
/// 每 60 秒的計時器只更新 `now`（讓選單列在沒有新資料時也會轉灰或顯示已重置）；
/// 只有在監看失效時（資料夾還不存在、被刪除重建）才改為輪詢讀檔並嘗試重新監看。
@Observable
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    let locator = UsageFileLocator()
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    /// 每分鐘更新，讓選單列在沒有新資料時也能轉灰或顯示已重置
    private(set) var now = Date.now

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var widgetThrottle = WidgetReloadThrottle()

    /// 測試時以 AI_USAGE_MONITOR_HOME 指向假資料，此時不寫入 App Group，避免動到真實資料夾。
    var usesCustomHome: Bool {
        !(ProcessInfo.processInfo.environment[UsageFileLocator.homeEnvironmentKey] ?? "").isEmpty
    }

    func start() {
        Self.log("reading \(locator.usageFile.path)")
        reload()
        watchDirectory()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { UsageStore.shared.tick() }
        }
        // 允許系統合併喚醒，閒置時更省電（NFR-8）
        timer.tolerance = 10
        self.timer = timer
    }

    private func tick() {
        now = .now
        if source == nil {
            // 監看失效：輪詢讀檔，並在資料夾出現後重新監看
            watchDirectory()
            reload()
        }
        reloadWidgetIfNeeded()
    }

    func reload() {
        do {
            let loaded = try locator.load()
            errorMessage = nil
            guard loaded != snapshot else { return }
            snapshot = loaded
            Self.log("loaded updated_at=\(loaded.updatedAt.ISO8601Format())")
            shareWithWidget()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            errorMessage = "找不到 usage.json，請確認 Mac 收集器正在執行"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func watchDirectory() {
        let fd = open(locator.directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log("cannot watch \(locator.directory.path), polling until it exists")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { UsageStore.shared.directoryChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        Self.log("watching \(locator.directory.path)")
    }

    private func directoryChanged() {
        guard let source else { return }
        // 資料夾本身被刪除或改名：舊的 fd 指向已不存在的資料夾，不會再收到事件。
        // 取消監看，交給計時器輪詢並重新監看。
        if !source.data.isDisjoint(with: [.delete, .rename]) {
            source.cancel()
            self.source = nil
            Self.log("directory moved or deleted, polling until it comes back")
        }
        reload()
    }

    /// 複製到 App Group 給小工具讀。只在 App 有 App Group entitlement（以 Team 簽署）時才寫入：
    /// 未簽署時小工具本來就讀不到，且 macOS 15 會對存取未授權的群組容器跳出詢問。
    private func shareWithWidget() {
        guard !usesCustomHome, SharedSnapshot.isEntitled, let url = SharedSnapshot.url, let snapshot,
              let data = try? UsageEncoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        reloadWidgetIfNeeded()
    }

    /// 收集器每 5 分鐘寫一次，每次都重新整理會超過 WidgetKit 的每日預算，改由節流決定。
    private func reloadWidgetIfNeeded() {
        guard !usesCustomHome, SharedSnapshot.isEntitled, let snapshot,
              widgetThrottle.shouldReload(for: snapshot, now: .now) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 寫到 stderr（不經緩衝），方便測試時從 log 確認讀取的路徑與資料時間。
    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[AIUsageMenuBar] \(message)\n".utf8))
    }
}
