// README 截圖的後製：裁切、縮放、圓角與細邊框（scripts/update-readme-images.sh 依 docs/images/SOURCES.tsv 呼叫）。
//
//   swiftc -O scripts/readme-image-post.swift -o build/readme-image-post
//   build/readme-image-post <PNG 或 GIF> [crop=<y>:<高> 或 crop=<x>:<y>:<寬>:<高>] [width=<寬>] [frame=<圓角半徑>]
//
// 不管參數順序，一律先裁切（原圖像素，從頂端 y 起留下指定高度；四個數字時另外從左邊 x 起留下指定寬度），再縮放到指定寬度（等比例），最後加框（縮放後的像素）。
// 框：圓角外變透明（GIF 改填 GitHub 頁面的底色，見 framed），沿圓角內緣畫寬度約 1 pt（寬度 ÷ 360，至少 1 像素）的邊框；
// 圖的外圈偏亮時用淡黑色、偏暗時用淡白色，讓白底與深色底的畫面在 GitHub 的淺色與深色頁面上都有輪廓。
// GIF 逐格處理，保留每格的停留時間與重複播放的設定。直接覆寫原檔。
// 結束碼：0＝完成，2＝參數錯誤，3＝讀不到或寫不出圖。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var crop: (x: Int, y: Int, width: Int?, height: Int)?
    var width: Int?
    var frame: Double?
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("readme-image-post：\(message)\n".utf8))
    exit(code)
}

func parse(_ args: ArraySlice<String>) -> Options {
    var options = Options()
    for arg in args {
        let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("看不懂參數 \(arg)", 2) }
        switch parts[0] {
        case "crop":
            let numbers = parts[1].split(separator: ":").compactMap { Int($0) }
            switch numbers.count {
            case 2 where numbers[0] >= 0 && numbers[1] > 0: options.crop = (0, numbers[0], nil, numbers[1])
            case 4 where numbers[0] >= 0 && numbers[1] >= 0 && numbers[2] > 0 && numbers[3] > 0:
                options.crop = (numbers[0], numbers[1], numbers[2], numbers[3])
            default: fail("crop 要寫成 crop=<y>:<高> 或 crop=<x>:<y>:<寬>:<高>", 2)
            }
        case "width":
            guard let width = Int(parts[1]), width > 0 else { fail("width 要是正整數", 2) }
            options.width = width
        case "frame":
            guard let radius = Double(parts[1]), radius >= 0 else { fail("frame 要是圓角半徑（像素）", 2) }
            options.frame = radius
        default:
            fail("不認得的參數 \(parts[0])", 2)
        }
    }
    return options
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func context(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("無法建立畫布", 3) }
    context.interpolationQuality = .high
    return context
}

func resized(_ image: CGImage, width: Int) -> CGImage {
    let height = max(Int((Double(image.height) * Double(width) / Double(image.width)).rounded()), 1)
    let canvas = context(width: width, height: height)
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return canvas.makeImage()!
}

/// 外圈 4 像素的平均亮度（0～1），用來決定邊框用淡黑或淡白
func edgeLuminance(_ image: CGImage) -> Double {
    let width = image.width, height = image.height
    let canvas = context(width: width, height: height)
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = canvas.data!.assumingMemoryBound(to: UInt8.self)
    let stride = canvas.bytesPerRow
    var total = 0.0, count = 0.0
    for y in 0..<height {
        for x in 0..<width where x < 4 || x >= width - 4 || y < 4 || y >= height - 4 {
            let p = data + y * stride + x * 4
            let alpha = Double(p[3]) / 255
            guard alpha > 0 else { continue }
            total += (0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])) / 255 / alpha
            count += 1
        }
    }
    return count > 0 ? total / count : 1
}

/// opaque：GIF 用。透明的圓角會讓 ImageIO 每格多存透明色，檔案大四倍以上，所以圓角外改填 GitHub 頁面的底色
/// （淺色 #ffffff、深色 #0d1117；README 以 <picture> 依讀者的系統挑淺色或深色版）
func framed(_ image: CGImage, radius: Double, light: Bool, opaque: Bool) -> CGImage {
    let width = image.width, height = image.height
    let border = max(Double(width) / 360, 1)
    let canvas = context(width: width, height: height)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    if opaque {
        canvas.setFillColor(light ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                                  : CGColor(srgbRed: 13 / 255, green: 17 / 255, blue: 23 / 255, alpha: 1))
        canvas.fill(bounds)
    }
    let r = min(radius, Double(min(width, height)) / 2)
    canvas.addPath(CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil))
    canvas.clip()
    canvas.draw(image, in: bounds)
    let inset = bounds.insetBy(dx: border / 2, dy: border / 2)
    let innerRadius = max(r - border / 2, 0)
    canvas.addPath(CGPath(roundedRect: inset, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
    canvas.setLineWidth(border)
    canvas.setStrokeColor(light ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14)
                                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
    canvas.strokePath()
    return canvas.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("用法：readme-image-post <PNG 或 GIF> [crop=<y>:<高> 或 <x>:<y>:<寬>:<高>] [width=<寬>] [frame=<半徑>]", 2) }
let url = URL(fileURLWithPath: arguments[1])
let options = parse(arguments.dropFirst(2))

guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
    fail("讀不到 \(url.lastPathComponent)", 3)
}
let count = CGImageSourceGetCount(source)
var frames: [(CGImage, CFDictionary?)] = []
var light: Bool?
for index in 0..<count {
    guard var image = CGImageSourceCreateImageAtIndex(source, index, nil) else { fail("讀不到第 \(index + 1) 格", 3) }
    if let crop = options.crop {
        let width = crop.width ?? image.width - crop.x
        guard crop.y + crop.height <= image.height, crop.x + width <= image.width,
              let cropped = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: width, height: crop.height)) else {
            fail("裁切範圍超出圖片（\(image.width)×\(image.height)）", 2)
        }
        image = cropped
    }
    if let width = options.width, width != image.width { image = resized(image, width: width) }
    if let radius = options.frame {
        if light == nil { light = edgeLuminance(image) >= 0.5 }  // GIF 以第一格決定，整段一致
        image = framed(image, radius: radius, light: light!, opaque: UTType(type as String) == .gif)
    }
    // 只保留 GIF 的停留時間；PNG 的 DPI 等屬性不帶過去（縮放後已不對）
    var properties: [CFString: Any] = [:]
    if let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
       let gif = frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
        properties[kCGImagePropertyGIFDictionary] = gif.filter {
            [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime].contains($0.key)
        }
    }
    frames.append((image, properties.isEmpty ? nil : properties as CFDictionary))
}

let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, count, nil) else {
    fail("寫不出 \(url.lastPathComponent)", 3)
}
if let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
   let gif = fileProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
   let loop = gif[kCGImagePropertyGIFLoopCount] {
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
}
for (image, properties) in frames { CGImageDestinationAddImage(destination, image, properties) }
guard CGImageDestinationFinalize(destination) else { fail("寫不出 \(url.lastPathComponent)", 3) }
do {
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
} catch {
    try? FileManager.default.removeItem(at: temporary)
    fail("無法覆寫 \(url.lastPathComponent)", 3)
}
