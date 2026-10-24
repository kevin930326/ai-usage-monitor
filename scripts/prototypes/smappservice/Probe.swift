// SMAppService 最小原型（ADR-0013 第 3 節）：ad-hoc 簽署的 App 能不能註冊自己內建的 LaunchAgent。
//   Probe register | status | unregister
// 只用於驗證，與正式 App 不同的 bundle ID 與 label；agent 只把時間寫到建置時指定的暫存資料夾。
import Foundation
import ServiceManagement

let service = SMAppService.agent(plistName: "io.github.kevin930326.AUMProbe.agent.plist")

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
do {
    switch command {
    case "register": try service.register()
    case "unregister": try service.unregister()
    default: break
    }
    print("\(command): ok, status=\(describe(service.status))")
} catch {
    let ns = error as NSError
    print("\(command): failed domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription); status=\(describe(service.status))")
    exit(1)
}
