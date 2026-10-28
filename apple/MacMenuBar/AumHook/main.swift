import Darwin
import Foundation
import UsageKit

// Claude Code／Codex 的 hook（ADR-0017 第 1 節）：`aum-hook <claude|codex>`，事件 JSON 從標準輸入傳入。
// 只挑事件、種類、加鹽雜湊後的工作階段 ID、時間、資料夾名稱送到 App 的 Unix socket，其餘欄位立刻丟掉。
// 標準輸出與標準錯誤一律不印任何東西（有些事件的輸出會加進 AI 的上下文）；任何錯誤都 exit 0、不擋 AI；
// 不連網路。

// 不論發生什麼都不輸出：先把標準輸出與標準錯誤接到 /dev/null
let null = open("/dev/null", O_WRONLY)
if null >= 0 {
    dup2(null, STDOUT_FILENO)
    dup2(null, STDERR_FILENO)
}
// 最多跑 1 秒（讀標準輸入卡住時也一樣），時間到以 0 結束
signal(SIGALRM) { _ in _exit(0) }
alarm(1)
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
if arguments.count >= 2, let ai = AgentKind(rawValue: arguments[1]), let input = AgentHookRunner.readInput() {
    let environment = ProcessInfo.processInfo.environment
    // 資料夾與 App 相同：AI_USAGE_MONITOR_HOME 優先，否則 ~/Library/Application Support/AIUsageMonitor。
    // hook 不是測試環境的判斷對象（AUM_TESTING 由 AI 的環境決定），所以不讓 locator 中止
    let directory = UsageFileLocator(environment: environment, testing: false).directory
    AgentHookRunner.run(ai: ai, input: input, directory: directory)
}
exit(0)
