// 截圖比對：逐一比較基準與新產生的 PNG，容許小誤差（字型反鋸齒、色彩轉換的 ±幾個色階）。
//
//   swiftc -O scripts/compare-snapshots.swift -o build/compare-snapshots
//   build/compare-snapshots <基準資料夾> <新截圖資料夾> <差異圖資料夾>
//
// 每個像素四個通道中差最多的那個超過 PIXEL_TOLERANCE（0～255）算「不同」；
// 不同的像素超過總數的 RATIO_TOLERANCE 或尺寸不同時，該張失敗並在差異圖資料夾輸出
// <名稱>-diff.png（不同的像素標紅，其他淡化）。基準有、新截圖沒有的也算失敗。
// 結束碼：0＝全部相符，1＝有不符，2＝參數或讀檔錯誤。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let pixelTolerance = Int(ProcessInfo.processInfo.environment["PIXEL_TOLERANCE"] ?? "") ?? 24
let ratioTolerance = Double(ProcessInfo.processInfo.environment["RATIO_TOLERANCE"] ?? "") ?? 0.002

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]  // RGBA，sRGB，premultiplied
}

func load(_ url: URL) -> Bitmap? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? Bitmap(width: width, height: height, pixels: pixels) : nil
}

func writeDiff(_ base: Bitmap, _ new: Bitmap, to url: URL) {
    var out = [UInt8](repeating: 0, count: base.pixels.count)
    for i in stride(from: 0, to: base.pixels.count, by: 4) {
        let differs = (0..<4).contains { abs(Int(base.pixels[i + $0]) - Int(new.pixels[i + $0])) > pixelTolerance }
        if differs {
            out[i] = 255; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 255
        } else {
            for c in 0..<3 { out[i + c] = UInt8(min(255, Int(new.pixels[i + c]) / 4 + 191)) }
            out[i + 3] = 255
        }
    }
    out.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: base.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("用法：compare-snapshots <基準資料夾> <新截圖資料夾> <差異圖資料夾>\n".data(using: .utf8)!)
    exit(2)
}
let baseDir = URL(fileURLWithPath: args[1]), newDir = URL(fileURLWithPath: args[2]), diffDir = URL(fileURLWithPath: args[3])
let names = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
guard !names.isEmpty else {
    print("沒有基準截圖：\(baseDir.path)")
    exit(2)
}
try? FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true)
var failed = 0
for name in names {
    guard let base = load(baseDir.appendingPathComponent(name)) else {
        print("FAIL \(name)：無法讀取基準")
        failed += 1
        continue
    }
    guard let new = load(newDir.appendingPathComponent(name)) else {
        print("FAIL \(name)：沒有產生這張截圖")
        failed += 1
        continue
    }
    guard base.width == new.width, base.height == new.height else {
        print("FAIL \(name)：尺寸 \(base.width)×\(base.height) → \(new.width)×\(new.height)")
        failed += 1
        continue
    }
    var differing = 0
    for i in stride(from: 0, to: base.pixels.count, by: 4)
    where (0..<4).contains(where: { abs(Int(base.pixels[i + $0]) - Int(new.pixels[i + $0])) > pixelTolerance }) {
        differing += 1
    }
    let ratio = Double(differing) / Double(base.width * base.height)
    if ratio > ratioTolerance {
        print(String(format: "FAIL %@：%.3f%% 的像素不同（容許 %.3f%%）", name, ratio * 100, ratioTolerance * 100))
        writeDiff(base, new, to: diffDir.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-diff.png")))
        failed += 1
    } else {
        print(String(format: "ok   %@（%.3f%%）", name, ratio * 100))
    }
}
print("compare-snapshots: \(names.count - failed)/\(names.count) 相符")
exit(failed == 0 ? 0 : 1)
