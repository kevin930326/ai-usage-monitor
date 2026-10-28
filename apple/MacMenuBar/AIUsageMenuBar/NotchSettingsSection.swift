import SwiftUI

/// 設定的「瀏海面板」（ADR-0016 第 4 節、MASCOT-SPEC 第 9 節）：開關（預設開）、角色、過場
struct NotchSettingsSection: View {
    @Environment(PanelSettings.self) private var settings
    /// 系統的「減少動態效果」（開著時「完整」當成「簡單」，設定頁要明確寫出來）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 8) {
            Text("瀏海面板").font(.headline)
            SwitchRow(title: "顯示瀏海面板",
                      detail: "滑鼠移到螢幕上方的瀏海會展開，顯示角色與額度；沒有瀏海的螢幕在選單列中間畫一個。選單列圖示與面板照常使用",
                      isOn: $settings.notchEnabled)
            if settings.notchEnabled {
                Text("角色").font(.subheadline.weight(.semibold)).padding(.top, 4)
                FlowChips(choices: MascotCharacter.allCases.map { ($0, $0.title) }, selected: settings.mascotCharacter) {
                    settings.mascotCharacter = $0
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
                Text("完整：點一下有隨機的小反應（跳一下、揮手、點頭、歪頭、偷笑、東張西望），繞圈、甩動、停在角色上也有反應，右鍵可以選所有動作與表情；額度提醒時跳一下，Claude 或 Codex 在跑時低頭敲鍵盤，睡著時呼吸。簡單：角色身體不動、只有眼睛會眨和看滑鼠，不播過場與反應，面板展開不回彈。關閉：角色完全靜止。三種都用眼睛的樣子顯示額度：正常是膠囊、剩不到 20% 是小圓點加擔心的眉毛、用完是 ×、資料過期時閉眼。「工作中」與睡覺只看紀錄檔的修改時間，不讀內容。")
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
