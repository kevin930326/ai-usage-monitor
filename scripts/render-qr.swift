// iPhone 配對的 QR 碼（ADR-0012）：在終端機用 Unicode 半格方塊畫出 `aiusage-pair:v1:<base64url(JSON)>`。
//
//   printf '%s\n%s\n' "$URL" "$READ_TOKEN" | swift scripts/render-qr.swift
//   swift scripts/render-qr.swift --decode < 畫出來的文字     # 測試用：把半格方塊還原成圖片，以 CIDetector 解碼
//
// 網址與讀取密鑰從標準輸入讀（不放在參數裡，ps 看不到）；不寫檔、不進剪貼簿。
// 以 CoreImage 的 CIQRCodeGenerator（糾錯等級 M）產生，不需要安裝 qrencode。
import CoreImage
import Foundation

let prefix = "aiusage-pair:v1:"
let quiet = 4  // QR 碼規格的留白（模組數）
let dark = "\u{1B}[30;47m", reset = "\u{1B}[0m"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func payload(url: String, token: String) -> String {
    guard let json = try? JSONSerialization.data(withJSONObject: ["url": url, "read": token], options: [.sortedKeys]) else {
        fail("無法產生配對內容")
    }
    let body = json.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return prefix + body
}

/// 每個模組一格，true 是深色
func modules(_ message: String) -> [[Bool]] {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { fail("CoreImage 沒有 QR 碼產生器") }
    filter.setValue(Data(message.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { fail("無法產生 QR 碼") }
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    // CoreImage 的原點在左下，第 0 列是最下面一列
    return (0..<height).reversed().map { y in (0..<width).map { x in pixels[(y * width + x) * 4] < 128 } }
}

func render(_ grid: [[Bool]]) -> String {
    let size = grid.count + quiet * 2
    func at(_ x: Int, _ y: Int) -> Bool {
        let gx = x - quiet, gy = y - quiet
        return gy >= 0 && gy < grid.count && gx >= 0 && gx < grid.count && grid[gy][gx]
    }
    var lines: [String] = []
    for y in stride(from: 0, to: size, by: 2) {
        var line = dark
        for x in 0..<size {
            switch (at(x, y), at(x, y + 1)) {
            case (true, true): line += "█"
            case (true, false): line += "▀"
            case (false, true): line += "▄"
            case (false, false): line += " "
            }
        }
        lines.append(line + reset)
    }
    return lines.joined(separator: "\n")
}

/// `render` 的反向：把半格方塊還原成每個模組 8×8 像素的灰階圖，再以 CIDetector 解碼
func decode(_ text: String) -> String? {
    let rows = text.replacingOccurrences(of: dark, with: "").replacingOccurrences(of: reset, with: "")
        .split(separator: "\n", omittingEmptySubsequences: true).map(Array.init)
    guard let width = rows.first?.count, width > 0 else { return nil }
    var grid: [[Bool]] = []
    for row in rows {
        grid.append(row.map { $0 == "█" || $0 == "▀" })
        grid.append(row.map { $0 == "█" || $0 == "▄" })
    }
    let scale = 8, w = width * scale, h = grid.count * scale
    var gray = [UInt8](repeating: 255, count: w * h)
    for (y, row) in grid.enumerated() {
        for (x, isDark) in row.enumerated() where isDark && x < width {
            for dy in 0..<scale { for dx in 0..<scale { gray[(y * scale + dy) * w + x * scale + dx] = 0 } }
        }
    }
    let image = CIImage(bitmapData: Data(gray), bytesPerRow: w, size: CGSize(width: w, height: h),
                        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
}

if CommandLine.arguments.dropFirst().first == "--decode" {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    guard let message = decode(text) else { fail("解碼失敗") }
    print(message)
    exit(0)
}

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
guard input.count >= 2, input[0].hasPrefix("https://"), !input[1].isEmpty else {
    fail("用法：printf '%s\\n%s\\n' <https 中繼網址> <讀取密鑰> | swift scripts/render-qr.swift")
}
print(render(modules(payload(url: input[0], token: input[1]))))
