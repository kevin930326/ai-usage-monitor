import Foundation
import Testing
@testable import UsageKit

/// C-10：手錶背景重新整理排程失敗時，要在有限次數內延後重試，不能讓背景更新就此中斷。
@Suite struct BackgroundRefreshRetryTests {
    @Test func retriesWithIncreasingDelay() throws {
        let first = try #require(BackgroundRefreshRetry.delay(afterFailures: 1))
        let second = try #require(BackgroundRefreshRetry.delay(afterFailures: 2))
        let third = try #require(BackgroundRefreshRetry.delay(afterFailures: 3))
        #expect(first >= 60)
        #expect(second > first)
        #expect(third > second)
    }

    @Test func stopsAfterLimit() {
        #expect(BackgroundRefreshRetry.delay(afterFailures: BackgroundRefreshRetry.maxAttempts + 1) == nil)
        #expect(BackgroundRefreshRetry.delay(afterFailures: 0) == nil)
    }

    @Test func schedulerRetriesUntilSuccess() async {
        // 第一次排程失敗、第二次成功：只多排一次，且等了重試延遲
        var results: [Bool] = [false, true]
        var waited: [TimeInterval] = []
        var attempts = 0
        await BackgroundRefreshRetry.schedule(
            attempt: { attempts += 1; return results.removeFirst() },
            sleep: { waited.append($0) }
        )
        #expect(attempts == 2)
        #expect(waited == [BackgroundRefreshRetry.delay(afterFailures: 1)!])
    }

    @Test func schedulerGivesUpAfterLimit() async {
        var attempts = 0
        var waited: [TimeInterval] = []
        await BackgroundRefreshRetry.schedule(
            attempt: { attempts += 1; return false },
            sleep: { waited.append($0) }
        )
        #expect(attempts == BackgroundRefreshRetry.maxAttempts + 1)
        #expect(waited.count == BackgroundRefreshRetry.maxAttempts)
    }

    @Test func retryAfterASynchronousFirstFailureWaitsFirst() async {
        // 第一次已在呼叫端同步失敗：先等第一段延遲再試，總共最多 maxAttempts＋1 次
        var attempts = 0
        var waited: [TimeInterval] = []
        await BackgroundRefreshRetry.schedule(
            alreadyFailed: 1,
            attempt: { attempts += 1; return false },
            sleep: { waited.append($0) }
        )
        #expect(attempts == BackgroundRefreshRetry.maxAttempts)
        #expect(waited.first == BackgroundRefreshRetry.delay(afterFailures: 1))
        #expect(waited.count == BackgroundRefreshRetry.maxAttempts)
    }
}
