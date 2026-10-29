import Foundation

/// 各段腳本（數值同 notch-demo.html；位置、時間取自 `MascotConfig`）。每個函式只描述「從 `base` 開始、之後怎麼動」，
/// 起點姿勢由呼叫端以上一段在那一刻的姿勢傳入。
public struct MascotScripts: Sendable {
    public let config: MascotConfig

    public init(config: MascotConfig) {
        self.config = config
    }

    private var hero: MascotConfig.Hero { config.hero }

    /// 休息時的手（REST）
    public var restHands: [MascotProp: Double] {
        let l = hero.handRest.left, r = hero.handRest.right
        return [.lx: l[0], .ly: l[1], .lz: l[2], .rx: r[0], .ry: r[1], .rz: r[2]]
    }

    /// 收合時的姿勢：瀏海左邊的迷你角色（`close` 的終點；App 啟動時直接用這個）
    public var collapsedPose: MascotPose {
        MascotPose([.x: hero.mini.x, .y: hero.mini.y, .r: hero.mini.radius, .sc: 1, .open: 1, .tint: 1, .dot: 1,
                    .follow: 1, .sx: 1, .sy: 1]).with(restHands)
    }

    /// 展開後角色卡上的靜止姿勢（截圖與「關閉過場」時的終點）
    public var cardPose: MascotPose {
        collapsedPose.with([.x: hero.card.x, .y: hero.card.y, .r: hero.card.radius, .glow: 0.5])
    }

    // MARK: - 過場（MASCOT-SPEC 第 4 節）

    public func intro(start: Int) -> MascotScript {
        let place = hero.intro
        var base = MascotPose([.x: place.x, .y: place.y + place.startDrop, .r: place.radius, .sc: 0,
                               .pitch: config.intro.startPitch, .open: 1, .dash: 1, .sx: 1, .sy: 1]).with(restHands)
        base[.tint] = 0
        var s = MascotScript(start: start, base: base)
        s.to([.sc: 1], 560, .back)
        s.to([.glow: 1], 600)
        s.to([.y: place.y], 760, .out, at: 100)
        s.to([.pitch: 0], 880, .backSoft, at: 100)
        s.to([.dash: 0], 170, at: 950)
        s.to([.yaw: -0.38, .roll: -0.05], 300, .inOut, at: 1150)
        s.to([.yaw: 0.32, .roll: 0.05], 340, .inOut, at: 1480)
        s.to([.yaw: 0, .roll: 0], 260, .inOut, at: 1850)
        s.to([.pitch: -0.5], 220, .inOut, at: 2100)
        s.to([.hands: 1], 440, .back, at: 2100)
        s.to([.pitch: 0.2, .yaw: -0.22], 360, .inOut, at: 2320)
        s.to([.wave: 1], 200, at: 2320)
        s.to([.sway: 0.8], 300, at: 2320)
        s.setEyes(.happy, at: 2500)
        s.setEyes(.pill, at: 3300)
        s.to([.wave: 0], 200, at: 3750)
        s.to([.sway: 0], 360, at: 3750)
        s.to([.dash: 1], 80, .inCubic, at: 3750)
        s.to([.dash: 0], 130, at: 3870)
        s.to([.hands: 0], 320, .inCubic, at: 3980)
        s.to([.tint: 1], 520, at: 3980)
        s.to([.dot: 1], 380, at: 3980)
        s.to([.pitch: 0, .yaw: 0], 320, .inOut, at: 3980)
        s.to([.x: hero.card.x, .y: hero.card.y, .r: hero.card.radius], 760, .expoOut, at: 4380)
        s.to([.glow: 0.5], 700, at: 4380)
        s.to([.follow: 1], 700, at: 4380)
        s.finalize()
        return s
    }

    /// 不播過場的展開：從迷你位置滑到角色卡
    public func quickOpen(start: Int, from base: MascotPose, mode: MascotMode) -> MascotScript {
        var s = MascotScript(start: start, base: base.with([.tint: 1, .dot: 1, .sc: 1]))
        appendRest(&s, mode: mode, duration: 300)
        s.to([.x: hero.card.x, .y: hero.card.y, .r: hero.card.radius], 620, .expoOut)
        s.to([.glow: 0.5], 500)
        s.finalize()
        return s
    }

    /// 從任何姿勢（含過場途中）接到卡片上目前模式的姿勢：同快速展開，但服務色、額度等級、大小也是漸變，不跳格
    /// （動畫程度改成靜止、或從靜止恢復時）
    public func settle(start: Int, from base: MascotPose, mode: MascotMode) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        appendRest(&s, mode: mode, duration: 300)
        s.to([.x: hero.card.x, .y: hero.card.y, .r: hero.card.radius], 620, .expoOut)
        s.to([.tint: 1, .dot: 1, .sc: 1], 300)
        s.to([.glow: 0.5], 500)
        s.finalize()
        return s
    }

    /// 收合時的姿勢依模式：睡覺時迷你角色也閉眼低頭（姿勢本身靜止；Mac 收合時的呼吸與小 z 由 App 以 Core Animation 另外播，ADR-0021）；
    /// 工作中低頭；其他模式是平常的迷你角色
    public func collapsedPose(mode: MascotMode) -> MascotPose {
        switch mode {
        case .sleep:
            // 迷你角色很小：頭只低一半，閉著的眼睛才不會落到最下緣、看起來像嘴巴
            return collapsedPose.with([.pitch: config.poses.sleep.pitch * 0.45, .dash: 1, .follow: 0])
        case .raise:
            // 需要你：迷你角色也舉手（收合時就看得到，靜止不重畫）
            return collapsedPose.with(raiseHands)
        case .work:
            // 工作中：低頭看鍵盤（同參考頁 −0.42），不看游標（`followsPointer`，2026-10-29）。手由 App 的收合循環另外畫
            return collapsedPose.with([.pitch: config.poses.work.pitch, .follow: 0])
        case .think:
            // 背景執行中：平常的迷你角色、臉朝正前方不看游標；思考泡泡與呼吸由 App 的收合循環另外畫
            return collapsedPose.with([.follow: 0])
        case .none:
            return collapsedPose
        }
    }

    /// 舉手的姿勢（展開與收合共用；位置、大小另外決定）
    private var raiseHands: [MascotProp: Double] {
        let r = config.poses.raise
        return [.hands: 1, .wave: 0, .pitch: r.pitch, .roll: r.roll, .yaw: 0,
                .lx: r.left[0], .ly: r.left[1], .lz: r.left[2], .rx: r.right[0], .ry: r.right[1], .rz: r.right[2]]
    }

    /// 收合時滑回迷你位置的屬性（`close` 與收合途中的 `collapsedCheer` 共用；揮手會動的手、頭的角度另外處理）
    private static let closeProps: [MascotProp] = [.x, .y, .r, .sc, .sway, .glow, .tint, .dot, .sx, .sy, .jump, .orbit, .shiver,
                                                   .blush, .type, .kb, .breathe]

    /// 收著時換姿勢會動到的屬性（`collapsedRest`、`close`、揮手後回位共用）
    private static let collapsedProps: [MascotProp] = [.pitch, .dash, .yaw, .roll, .hands, .wave,
                                                       .lx, .ly, .lz, .rx, .ry, .rz]

    /// 收著時換模式（睡著、醒來、舉手、放下）：迷你角色換姿勢一次（.4 秒），之後靜止
    public func collapsedRest(start: Int, from base: MascotPose, mode: MascotMode) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        let target = collapsedPose(mode: mode)
        s.to(Dictionary(uniqueKeysWithValues: Self.collapsedProps.map { ($0, target[$0]) }), 400, .inOut)
        s.to([.follow: target[.follow]], 300)
        s.finalize()
        return s
    }

    /// 收著時 AI 完成：迷你角色舉起右手揮一下，再回到目前模式的姿勢（瀏海鼓一下由 `MascotPanelSpring.bump` 計算）。
    /// 收合途中完成時，位置、大小與其他收合時會變的屬性照樣滑回迷你位置（Codex C-01）
    public func collapsedCheer(start: Int, from base: MascotPose, mode: MascotMode) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        let mini = collapsedPose(mode: mode)
        s.to(Dictionary(uniqueKeysWithValues: Self.closeProps.map { ($0, mini[$0]) }), config.panel.closeGlideMs, .inOut)
        let wave = config.poses.cheerWaveMs
        s.to([.hands: 1, .pitch: 0, .dash: 0], 200, .back)
        s.to([.wave: 1], 200)
        s.setEyes(.happy, at: 150)
        s.setEyes(.pill, at: 150 + wave)
        s.to([.wave: 0], 200, at: 200 + wave)
        let target = collapsedPose(mode: mode)
        s.to(Dictionary(uniqueKeysWithValues: Self.collapsedProps.map { ($0, target[$0]) }), 320, .inOut, at: 300 + wave)
        s.finalize()
        return s
    }

    /// 收合：角色縮回瀏海左邊的迷你位置（同一顆球連續移動）；睡覺中的收成閉眼的迷你角色
    public func close(start: Int, from base: MascotPose, mode: MascotMode = .none) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        let mini = collapsedPose(mode: mode)
        var target: [MascotProp: Double] = [:]
        for prop in Self.closeProps + [.hands, .wave, .dash, .pitch, .yaw, .roll] + (mode == .raise ? Self.collapsedProps : []) {
            target[prop] = mini[prop]
        }
        s.to(target, config.panel.closeGlideMs, .inOut)
        s.to([.follow: mini[.follow]], 200)
        s.finalize()
        return s
    }

    // MARK: - 模式姿勢

    /// 動畫播完、回到目前模式的姿勢（平常 .32 秒；工作中 .38 秒）
    public func rest(start: Int, from base: MascotPose, mode: MascotMode) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        appendRest(&s, mode: mode, duration: nil)
        s.finalize()
        return s
    }

    private func appendRest(_ s: inout MascotScript, mode: MascotMode, duration: Int?) {
        s.setEyes(.pill)
        switch mode {
        case .work:
            let w = config.poses.work
            s.to([.sx: 1, .sy: 1, .jump: 0, .orbit: 0, .shiver: 0, .blush: 0, .yaw: 0, .pitch: w.pitch, .roll: 0, .dash: 0,
                  .hands: 1, .wave: 0, .sway: 0, .breathe: 0, .type: 1, .kb: 1, .follow: w.follow,
                  .lx: w.left[0], .ly: w.left[1], .lz: w.left[2], .rx: w.right[0], .ry: w.right[1], .rz: w.right[2]],
                 duration ?? config.poses.workMs, .inOut)
        case .sleep:
            let sleep = config.poses.sleep
            s.to([.pitch: sleep.pitch, .yaw: 0, .roll: 0, .dash: 1, .hands: 0, .wave: 0, .type: 0, .kb: 0, .breathe: 1,
                  .glow: sleep.glow, .follow: 0], duration ?? sleep.enterMs, .inOut)
        case .raise:
            s.to([.sx: 1, .sy: 1, .jump: 0, .orbit: 0, .shiver: 0, .blush: 0, .dash: 0, .sway: 0, .breathe: 0,
                  .type: 0, .kb: 0, .follow: 1].merging(raiseHands) { $1 }, duration ?? config.poses.raiseMs, .backSoft)
        case .none, .think:
            // 背景執行中展開時和平常一樣（眨眼、看滑鼠）；狀態寫在工作階段列表
            var target: [MascotProp: Double] = [.sx: 1, .sy: 1, .jump: 0, .orbit: 0, .shiver: 0, .blush: 0, .yaw: 0,
                                                .pitch: 0, .roll: 0, .dash: 0, .hands: 0, .wave: 0, .sway: 0, .breathe: 0,
                                                .type: 0, .kb: 0, .follow: 1]
            target.merge(restHands) { $1 }
            s.to(target, duration ?? config.poses.restMs, .inOut)
        }
    }

    // MARK: - 收著時的提醒

    /// 收合時的提醒：迷你角色跳一下（瀏海鼓一下由 `MascotPanelSpring.bump` 計算）
    public func collapsedAlert(start: Int, from base: MascotPose, level: Int) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        s.effect(.ring(level: level), duration: 900)
        Self.hop(&s, height: config.expressions.collapsedAlert.hop)
        s.finalize()
        return s
    }

    /// 跳一下的壓扁、起跳、落地、回彈（demo 的 hopSeq）
    static func hop(_ s: inout MascotScript, height: Double, at offset: Int = 0) {
        s.to([.sx: 1.16, .sy: 0.84], 110, .out, at: offset)
        s.to([.jump: -height, .sx: 0.9, .sy: 1.12], 230, .out, at: offset + 110)
        s.to([.jump: 0, .sx: 0.96, .sy: 1.05], 190, .inCubic, at: offset + 340)
        s.to([.sx: 1.14, .sy: 0.86], 80, .out, at: offset + 530)
        s.to([.sx: 0.96, .sy: 1.04], 120, .inOut, at: offset + 610)
        s.to([.sx: 1, .sy: 1], 150, .inOut, at: offset + 730)
    }
}
