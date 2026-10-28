import Foundation
import Observation
import UsageKit

/// 讀取並監看本機 `usage.json`（FR-20）。收集器以「寫暫存檔再改名」更新，
/// 監看檔案本身會在改名後失效，所以監看所在資料夾。
/// 每 60 秒的計時器只更新 `now`（讓選單列在沒有新資料時也會轉灰或顯示已重置）；
/// 只有在監看失效時（資料夾還不存在、被刪除重建）才改為輪詢讀檔並嘗試重新監看。
@Observable
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    /// HistoryStore 也用這個位置。截圖與量測（Debug 的 `AUM_DEMO_PANEL`、`AUM_RENDER_DIR`）算測試環境：
    /// 沒有設定 AI_USAGE_MONITOR_HOME 時直接中止，不讀寫真的資料夾
    let locator: UsageFileLocator = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["AUM_DEMO_PANEL"] == "1" || env["AUM_RENDER_DIR"] != nil { return UsageFileLocator(testing: true) }
        #endif
        return UsageFileLocator()
    }()
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    /// 收集器寫的服務狀態（FR-45）；沒有檔案或讀不懂時為 nil
    private(set) var serviceStatus: ServiceStatusFile?
    /// 每分鐘更新，讓選單列在沒有新資料時也能轉灰或顯示已重置
    private(set) var now = RenderClock.now

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?

    /// 測試時以 AI_USAGE_MONITOR_HOME 指向假資料（「更新」按鈕此時不觸發真的收集器）。
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
        now = RenderClock.now
        if source == nil {
            // 監看失效：輪詢讀檔，並在資料夾出現後重新監看
            watchDirectory()
            reload()
        }
        // 重置時間到了（快照沒變）也要判斷通知
        QuotaNotifier.shared.evaluate(snapshot: snapshot, now: now)
        MascotController.shared.updateStatus()
    }

    func reload() {
        loadServiceStatus()
        // 讀檔失敗與恢復都要更新角色的表情（閉眼／照額度；Codex C-04）
        let failedBefore = errorMessage != nil
        defer { if failedBefore != (errorMessage != nil) { MascotController.shared.updateStatus() } }
        do {
            let loaded = try locator.load()
            errorMessage = nil
            guard loaded != snapshot else { return }
            snapshot = loaded
            Self.log("loaded updated_at=\(loaded.updatedAt.ISO8601Format())")
            QuotaNotifier.shared.evaluate(snapshot: loaded, now: .now)
            MascotController.shared.updateStatus()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            errorMessage = "找不到 usage.json，請確認 Mac 收集器正在執行"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 服務狀態檔很小（幾 KB），每次資料夾有變動就重讀；內容相同時不觸發畫面更新
    private func loadServiceStatus() {
        let url = locator.directory.appendingPathComponent(ServiceStatusFile.fileName)
        let loaded = (try? Data(contentsOf: url)).flatMap(ServiceStatusFile.decode)
        if loaded != serviceStatus { serviceStatus = loaded }
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
        // 面板開著時：history.sqlite3 剛建立、或收集器關閉連線時 -wal 被合併刪除，也要重新查詢
        HistoryStore.shared.collectorWrote()
    }

    /// 寫到 stderr（不經緩衝），方便測試時從 log 確認讀取的路徑與資料時間。
    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[AIUsageMenuBar] \(message)\n".utf8))
    }
}
