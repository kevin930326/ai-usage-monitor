#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UsageKit

/// 看滑鼠時的角色圖層（`MascotHeroLayerView`，CoreGraphics）和瀏海畫布（SwiftUI）畫出來要一樣（icons 第 4 部分）：
/// 每種角色、外觀、表情、視線與特效各畫一格，兩邊逐像素比較，結果寫到 `hero-parity.tsv`，差太多的另存兩張圖。
/// `AUM_RENDER_DIR` 截圖時一起跑（`scripts/snapshots.sh` 依結果判斷）
@MainActor
enum DebugHeroParity {
    /// 一個像素四個通道中差最多的那個超過這個值，就算「不一樣」（抗鋸齒的細微差異不算）
    static let pixelTolerance = 40
    /// 「不一樣」的像素超過角色面積的這個比例就失敗
    static let areaTolerance = 0.01

    static func run(to dir: URL) {
        guard let data = MascotController.bundledConfig(), let config = try? MascotConfig.decode(data) else { return }
        let looks = MascotController.bundledLooks().flatMap { try? MascotLooks.decode($0) }?.looks ?? []
        var lines = ["case\tdiffering\tarea\tmax\tresult"]
        var cases: [(String, MascotFrame, CGRect)] = []
        for open in [false, true] {
            var d = MascotDirector(config: config, seed: 7, startTime: 0)
            if open { d.open(at: 0, intro: false) }
            d.advance(to: 2000)
            let pose = d.pose(at: 2000)
            let r = pose[.r] * pose[.sc]
            let half = (r * 3.1 + 6).rounded(.up)
            let box = CGRect(x: pose[.x] - half, y: pose[.y] - half, width: half * 2, height: half * 2)
            func frame(_ character: MascotCharacter, look: MascotLook?, gaze: (Double, Double), mood: MascotMood = .normal,
                       time: Int = 2000, thinking: Bool = false, blink: Double = 0) -> MascotFrame {
                MascotFrame(time: time, pose: d.pose(at: 2000), eyes: d.eyes(at: 2000), blink: blink, gazeYaw: gaze.0, gazePitch: gaze.1,
                            statusColor: 0, mood: mood, sleeping: false, thinkingDots: thinking ? 2 : nil, remoteBadge: thinking,
                            remoteBadgeAbove: open, effects: [], ripple: nil, character: character, look: look,
                            effectTime: look?.style.animates == true ? time : nil)
            }
            let side = open ? "open" : "collapsed"
            for character in MascotCharacter.allCases {
                for gaze in [(0.0, 0.0), (0.45, -0.25), (-0.5, 0.3)] {
                    cases.append(("\(side)-\(character.rawValue)-gaze\(gaze.0)", frame(character, look: nil, gaze: gaze), box))
                }
            }
            for mood in MascotMood.allCases where mood != .normal {
                cases.append(("\(side)-mood-\(mood.rawValue)", frame(.claude, look: nil, gaze: (0.3, -0.1), mood: mood), box))
                // 視線轉到最旁邊：冷汗這類畫在眼睛上面的東西和眼睛重疊時，疊放順序也要一樣（Fable G2-06）
                cases.append(("\(side)-mood-\(mood.rawValue)-side", frame(.claude, look: nil, gaze: (0.6, -0.3), mood: mood), box))
            }
            for look in looks {
                cases.append(("\(side)-look-\(look.id)", frame(.claude, look: look, gaze: (0.3, -0.15), time: 2400), box))
            }
            cases.append(("\(side)-remote", frame(.codex, look: nil, gaze: (0, 0), thinking: true), box))
            // 看滑鼠時眨眼也畫在圖層上（第三版：不再切回 SwiftUI）
            for blink in [0.35, 0.7, 1.0] {
                for character in MascotCharacter.allCases {
                    cases.append(("\(side)-\(character.rawValue)-blink\(blink)", frame(character, look: nil, gaze: (0.4, -0.2), blink: blink), box))
                }
            }
            for mood in MascotMood.allCases where mood != .normal {
                cases.append(("\(side)-mood-\(mood.rawValue)-blink", frame(.claude, look: nil, gaze: (0.3, -0.1), mood: mood, blink: 0.6), box))
            }
            // 播完的提醒光環還留在陣列裡：要拆層，畫出來也要一樣（Codex 第五輪 C-01）
            var expired = frame(.claude, look: nil, gaze: (0.4, -0.2))
            expired.effects = [MascotEffect(kind: .ring(level: 1), start: 0, duration: 900)]
            cases.append(("\(side)-expired-effect", expired, box))
        }
        var failed = 0
        for (name, frame, box) in cases {
            let painter = MascotPainter(config: config)
            let swiftUI = ImageRenderer(content: Canvas(rendersAsynchronously: false) { context, _ in
                context.translateBy(x: -box.minX, y: -box.minY)
                painter.drawCharacter(frame, in: &context)
            }.frame(width: box.width, height: box.height))
            swiftUI.scale = 2
            guard let a = swiftUI.cgImage.flatMap(rgba), let b = coreGraphics(frame, painter: painter, box: box, scale: 2).flatMap(rgba),
                  a.width == b.width, a.height == b.height else {
                lines.append("\(name)\t-\t-\t-\tfail")
                failed += 1
                continue
            }
            var differing = 0, area = 0, worst = 0
            for i in stride(from: 0, to: a.bytes.count, by: 4) {
                let d = (0..<4).map { abs(Int(a.bytes[i + $0]) - Int(b.bytes[i + $0])) }.max() ?? 0
                if a.bytes[i + 3] > 0 || b.bytes[i + 3] > 0 { area += 1 }
                if d > pixelTolerance { differing += 1 }
                worst = max(worst, d)
            }
            let ok = Double(differing) <= Double(max(area, 1)) * areaTolerance
            if !ok {
                failed += 1
                if let image = swiftUI.cgImage { write(image, to: dir.appendingPathComponent("hero-parity-\(name)-swiftui.png")) }
                if let image = coreGraphics(frame, painter: painter, box: box, scale: 2) {
                    write(image, to: dir.appendingPathComponent("hero-parity-\(name)-cg.png"))
                }
            }
            lines.append("\(name)\t\(differing)\t\(area)\t\(worst)\t\(ok ? "ok" : "fail")")
        }
        lines.append("# \(cases.count - failed)/\(cases.count) ok")
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("hero-parity.tsv"), atomically: true, encoding: .utf8)
        UsageStore.log("hero parity: \(cases.count - failed)/\(cases.count) ok")
    }

    /// 量測用（`AUM_RENDER_NAME=hero-bench`）：看滑鼠的一格各段花多少 CPU（不需要螢幕），寫到 `hero-bench.tsv`
    static func bench(to dir: URL) {
        guard let data = MascotController.bundledConfig(), let config = try? MascotConfig.decode(data) else { return }
        func cpu() -> Double {
            var t = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
            return Double(t.tv_sec) * 1e6 + Double(t.tv_nsec) / 1e3
        }
        var lines = ["step\tside\tus_per_frame"]
        for open in [false, true] {
            var d = MascotDirector(config: config, seed: 7, startTime: 0)
            if open { d.open(at: 0, intro: false) }
            d.advance(to: 2000)
            let pose = d.pose(at: 2000)
            let r = pose[.r] * pose[.sc]
            let half = (r * 3.1 + 6).rounded(.up)
            let box = CGRect(x: pose[.x] - half, y: pose[.y] - half, width: half * 2, height: half * 2)
            let painter = MascotPainter(config: config)
            let n = 600
            func frame(_ i: Int) -> MascotFrame {
                let t = 2000 + i * 16
                return MascotFrame(time: t, pose: pose, eyes: d.eyes(at: t), blink: d.blink(at: t), gazeYaw: sin(Double(i) / 20) * 0.4,
                                   gazePitch: 0.1, statusColor: d.statusColor(at: t), mood: d.mood(at: t), sleeping: false,
                                   thinkingDots: nil, effects: [], ripple: nil, character: .claude, look: nil, effectTime: nil)
            }
            let side = open ? "open" : "collapsed"
            var t0 = cpu()
            for i in 0..<n { _ = frame(i) }
            lines.append("frame\t\(side)\t\(String(format: "%.1f", (cpu() - t0) / Double(n)))")
            t0 = cpu()
            for i in 0..<n { _ = d.pose(at: 2000 + i * 16) }
            lines.append("pose\t\(side)\t\(String(format: "%.1f", (cpu() - t0) / Double(n)))")
            let f0 = frame(0)
            let face = MascotHeroLayerView.faceBox(f0, at: painter.heroCenter(f0))
            for (name, area, parts) in [("face", face, MascotPainter.Parts.face), ("whole", box, [.body, .face])] {
                let w = Int(area.width * 2), h = Int(area.height * 2)
                guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                cg.translateBy(x: 0, y: CGFloat(h))
                cg.scaleBy(x: 2, y: -2)
                let frames = (0..<n).map(frame)
                t0 = cpu()
                for f in frames {
                    cg.clear(CGRect(x: 0, y: 0, width: area.width, height: area.height))
                    MascotHeroLayerView.paint(f, parts: parts, painter: painter, box: area, clip: nil, in: cg)
                }
                lines.append("\(name)\t\(side)\t\(String(format: "%.1f", (cpu() - t0) / Double(n)))")
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("hero-bench.tsv"), atomically: true, encoding: .utf8)
    }

    /// 和 `MascotHeroLayerView` 同一份畫法：身體只會平移時先畫身體、再畫臉（同兩層疊起來；臉只畫在同一塊 `faceBox` 裡，
    /// 裁掉東西的話比對會失敗，Codex C-03），否則整個一起畫
    static func coreGraphics(_ frame: MascotFrame, painter: MascotPainter, box: CGRect, scale: Double) -> CGImage? {
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        if MascotPainter.bodyIsRigid(frame), let body = MascotHeroLayerView.image(frame, parts: .body, painter: painter, box: box,
                                                                                  clip: nil, scale: scale) {
            cg.saveGState()
            cg.translateBy(x: 0, y: box.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(body, in: CGRect(origin: .zero, size: box.size))
            cg.restoreGState()
            let face = MascotHeroLayerView.faceBox(frame, at: painter.heroCenter(frame)).offsetBy(dx: -box.minX, dy: -box.minY)
            cg.saveGState()
            cg.clip(to: face)
            MascotHeroLayerView.paint(frame, parts: .face, painter: painter, box: box, clip: nil, in: cg)
            cg.restoreGState()
        } else {
            MascotHeroLayerView.paint(frame, parts: [.body, .face], painter: painter, box: box, clip: nil, in: cg)
        }
        return cg.makeImage()
    }

    private struct Pixels { var width: Int; var height: Int; var bytes: [UInt8] }

    private static func rgba(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let cg = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Pixels(width: w, height: h, bytes: bytes) : nil
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
