import Foundation
import Observation
import UsageKit
import WidgetKit

/// 讀取並監看本機 `usage.json`（FR-20）。收集器以「寫暫存檔再改名」更新，
/// 監看檔案本身會在改名後失效，所以監看所在資料夾，另以 60 秒輪詢備援。
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

    /// 測試時以 AI_USAGE_MONITOR_HOME 指向假資料，此時不寫入 App Group，避免動到真實資料夾。
    private var usesCustomHome: Bool {
        !(ProcessInfo.processInfo.environment[UsageFileLocator.homeEnvironmentKey] ?? "").isEmpty
    }

    func start() {
        Self.log("reading \(locator.usageFile.path)")
        reload()
        watchDirectory()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                UsageStore.shared.now = .now
                UsageStore.shared.reload()
            }
        }
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
            Self.log("cannot watch \(locator.directory.path), polling only")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { UsageStore.shared.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func shareWithWidget() {
        guard !usesCustomHome, let url = SharedSnapshot.url, let snapshot else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 寫到 stderr（不經緩衝），方便測試時從 log 確認讀取的路徑與資料時間。
    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[AIUsageMenuBar] \(message)\n".utf8))
    }
}
