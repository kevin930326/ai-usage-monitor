import SwiftUI

/// 設定的「瀏海面板」（ADR-0016 第 4 節、MASCOT-SPEC 第 9 節）：開關（預設開）、角色、過場
struct NotchSettingsSection: View {
    @Environment(PanelSettings.self) private var settings

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
            }
        }
    }
}
