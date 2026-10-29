import SwiftUI

/// 設定的「瀏海面板」（ADR-0016 第 4 節、MASCOT-SPEC 第 9 節）：開關（預設開）、角色、過場
struct NotchSettingsSection: View {
    @Environment(PanelSettings.self) private var settings
    /// 系統的「減少動態效果」（開著時「完整」當成「簡單」，設定頁要明確寫出來）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 想同時關掉瀏海面板與選單列圖示時的說明
    @State private var note: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 8) {
            Text("瀏海面板").font(.headline)
            SwitchRow(title: "顯示瀏海面板",
                      detail: "滑鼠移到螢幕上方的瀏海會展開，顯示角色與額度；沒有瀏海的螢幕在選單列中間畫一個。選單列圖示與面板照常使用",
                      isOn: Binding(get: { settings.notchEnabled }, set: { on in
                          if !on, !settings.canDisableNotch {
                              note = "選單列圖示關著：瀏海面板是唯一的入口，不能也關掉。先在上面打開「顯示選單列圖示」。"
                              return
                          }
                          note = nil
                          settings.notchEnabled = on
                      }))
            if let note {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.notchEnabled {
                SwitchRow(title: "點瀏海直接打開完整面板",
                          detail: "點收合的瀏海（中間那一塊）打開和選單列一樣的完整面板；滑過仍是原本的展開",
                          isOn: $settings.notchClickOpensPanel)
                Text("角色").font(.subheadline.weight(.semibold)).padding(.top, 4)
                FlowChips(choices: MascotCharacter.allCases.map { ($0, $0.title) }, selected: settings.mascotCharacter) {
                    settings.mascotCharacter = $0
                }
                if let config = MascotController.shared.baseConfig, let looks = MascotController.shared.looks {
                    Text("角色外觀").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    MascotLookPicker(config: config, looks: looks, character: settings.mascotCharacter,
                                     selected: looks.look(settings.mascotLook)?.id) { settings.mascotLook = $0 }
                    Text("預設跟著服務（Claude 珊瑚、Codex 青瓷）。特效在展開時會動；收合時只在 AI 工作中動（每秒最多 12 次），閒置與睡著時停住。角色動畫是「簡單」「關閉」或系統開了「減少動態效果」時一律靜止。選單列圖示用同一個外觀的靜態圖；LED、像素、ASCII 在選單列太小、看不出表情，改畫該外觀主色的球。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("過場").font(.subheadline.weight(.semibold)).padding(.top, 4)
                FlowChips(choices: NotchIntroChoice.allCases.map { ($0, $0.title) }, selected: settings.notchIntro) {
                    settings.notchIntro = $0
                }
                Text("展開時角色出場的動畫（約 4.7 秒）。系統開了「減少動態效果」時不播。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("角色動畫").font(.subheadline.weight(.semibold)).padding(.top, 4)
                FlowChips(choices: MascotMotionLevel.allCases.map { ($0, $0.title) }, selected: settings.mascotMotion) {
                    settings.mascotMotion = $0
                }
                if settings.mascotMotion == .full && reduceMotion {
                    Label("系統開了「減少動態效果」，所以目前以「簡單」顯示：角色身體不動、只有眼睛會眨和看滑鼠。關掉系統設定的「減少動態效果」就會恢復完整。",
                          systemImage: "info.circle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("完整：點一下有隨機的小反應（跳一下、揮手、點頭、歪頭、偷笑、東張西望），繞圈、甩動、停在角色上也有反應，右鍵可以選所有動作與表情；額度提醒時跳一下，Claude 或 Codex 在跑時低頭敲鍵盤，睡著時呼吸。簡單：角色身體不動、只有眼睛會眨和看滑鼠，不播過場與反應，面板展開不回彈。關閉：角色完全靜止。三種都用眼睛的樣子顯示額度：正常是膠囊、剩不到 20% 是小圓點加擔心的眉毛、用完是 ×、資料過期時閉眼。「工作中」與睡覺照下面「AI 狀態」連接的 hook；沒連接的 AI 只看紀錄檔的修改時間，不讀內容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SwitchRow(title: "眼睛跟著游標",
                          detail: "整個螢幕都看，只讀游標位置、不需要權限",
                          isOn: $settings.mascotFollowPointer)
                Text("睡覺").font(.subheadline.weight(.semibold)).padding(.top, 4)
                FlowChips(choices: PanelSettings.sleepMinuteChoices.map { ($0, "\($0) 分鐘") }, selected: settings.mascotSleepMinutes) {
                    settings.mascotSleepMinutes = $0
                }
                Text("Claude 與 Codex 都閒置超過這麼久，角色就睡著（收合時迷你角色也閉眼）；開始用就醒來。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
