import Testing
@testable import UsageKit

/// FR-30：iPhone 與手錶以 sendMessage 交換中繼設定的訊息內容（#39 的邏輯層）。
struct WatchSettingsMessageTests {
    @Test func requestIsRecognised() {
        #expect(WatchSettingsMessage.isRequest(WatchSettingsMessage.request))
        #expect(!WatchSettingsMessage.isRequest([:]))
        #expect(!WatchSettingsMessage.isRequest(["requestSettings": "yes"]))
        #expect(!WatchSettingsMessage.isRequest(["requestSettings": false]))
    }

    @Test func settingsCarryBothValuesCleaned() {
        let message = WatchSettingsMessage.settings(url: " https://relay.example \n", token: "tok\n")
        #expect(message["relayURL"] as? String == "https://relay.example")
        #expect(message["readToken"] as? String == "tok")
        #expect(message.count == 2)
    }

    @Test(arguments: [("", "tok"), ("https://relay.example", ""), ("  \n", "tok"), ("", "")])
    func incompleteSettingsAreEmpty(url: String, token: String) {
        #expect(WatchSettingsMessage.settings(url: url, token: token).isEmpty)
    }

    @Test func replyOnlyAnswersARequestAndOnlyWhenConfigured() {
        let configured = WatchSettingsMessage.reply(to: WatchSettingsMessage.request, url: "https://r", token: "t")
        #expect(configured["relayURL"] as? String == "https://r")
        #expect(configured["readToken"] as? String == "t")
        #expect(WatchSettingsMessage.reply(to: WatchSettingsMessage.request, url: "", token: "t").isEmpty)
        #expect(WatchSettingsMessage.reply(to: WatchSettingsMessage.request, url: "https://r", token: "").isEmpty)
        #expect(WatchSettingsMessage.reply(to: ["hello": true], url: "https://r", token: "t").isEmpty)
        #expect(WatchSettingsMessage.reply(to: [:], url: "https://r", token: "t").isEmpty)
    }

    @Test func parseRoundTripsAndCleans() {
        let parsed = WatchSettingsMessage.parse(WatchSettingsMessage.settings(url: "https://r", token: "t"))
        #expect(parsed?.url == "https://r")
        #expect(parsed?.token == "t")
        // 較舊的 iPhone App 送來帶換行的值
        let legacy = WatchSettingsMessage.parse(["relayURL": "https://r\n", "readToken": " t\r\n"])
        #expect(legacy?.url == "https://r")
        #expect(legacy?.token == "t")
    }

    @Test func unusableMessagesAreIgnored() {
        // [String: Any] 不是 Sendable，不能當 @Test 的參數，所以在這裡逐一檢查
        let messages: [[String: Any]] = [
            [:],
            ["relayURL": "https://r"],
            ["readToken": "t"],
            ["relayURL": 1, "readToken": "t"],
            ["relayURL": "https://r", "readToken": ["t"]],
            ["relayURL": "https://r", "readToken": "  \n"],
            ["requestSettings": true],
        ]
        for message in messages {
            #expect(WatchSettingsMessage.parse(message) == nil, "\(message)")
        }
    }

    @Test func legacyContextIsClearedOnlyWhenAllConditionsHold() {
        #expect(WatchSettingsMessage.shouldClearLegacyContext(activated: true, paired: true, watchAppInstalled: true, contextIsEmpty: false))
        #expect(!WatchSettingsMessage.shouldClearLegacyContext(activated: false, paired: true, watchAppInstalled: true, contextIsEmpty: false))
        #expect(!WatchSettingsMessage.shouldClearLegacyContext(activated: true, paired: false, watchAppInstalled: true, contextIsEmpty: false))
        #expect(!WatchSettingsMessage.shouldClearLegacyContext(activated: true, paired: true, watchAppInstalled: false, contextIsEmpty: false))
        #expect(!WatchSettingsMessage.shouldClearLegacyContext(activated: true, paired: true, watchAppInstalled: true, contextIsEmpty: true))
    }
}
