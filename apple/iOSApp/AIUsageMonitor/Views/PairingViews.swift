import SwiftUI
import UsageKit
import UsageKitUI
import VisionKit

/// iPhone 配對（ADR-0012）：掃描 Mac 終端機顯示的 QR 碼。只接受 `aiusage-pair:v1:` 開頭、格式正確的內容。
struct PairingScannerSheet: View {
    let onScan: (PairingPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rejected = false

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            QRScanner { text in
                guard let payload = PairingPayload(scanned: text) else {
                    // 不顯示掃到的內容（可能是別的 QR 碼，也可能含密鑰）
                    rejected = true
                    return false
                }
                onScan(payload)
                dismiss()
                return true
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text(rejected ? "這不是配對用的 QR 碼。請在 Mac 執行 scripts/setup-iphone.sh --pair qr" : "對準 Mac 終端機上的 QR 碼")
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 32)
            }
            .navigationTitle("掃描 QR 碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

/// VisionKit 的掃描畫面，只辨識 QR 碼；`onText` 回傳 true 時停止掃描
private struct QRScanner: UIViewControllerRepresentable {
    let onText: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onText: (String) -> Bool
        private var done = false
        init(onText: @escaping (String) -> Bool) { self.onText = onText }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue else { continue }
                if onText(text) {
                    done = true
                    scanner.stopScanning()
                    return
                }
            }
        }
    }
}

/// 一次性短碼（ADR-0012）：輸入中繼網址與 Mac 上顯示的 8 碼，向中繼兌換讀取密鑰。
struct PairingCodeSheet: View {
    let initialURL: String
    let onPaired: (RelayClient) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    private var cleanURL: String { RelayInput.clean(url) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ai-usage-relay.帳號.workers.dev", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("短碼（例如 7K3M-Q9TD）", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("在 Mac 執行 scripts/setup-iphone.sh --pair code 取得短碼。短碼 10 分鐘內有效、只能用一次。")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.circle.fill").foregroundStyle(UsageColors.notice)
                    }
                }
            }
            .navigationTitle("輸入短碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("配對") { Task { await claim() } }
                            .disabled(cleanURL.isEmpty || PairingCode.normalize(code) == nil)
                    }
                }
            }
            .onAppear { url = initialURL }
        }
    }

    private func claim() async {
        working = true
        defer { working = false }
        do {
            let client = try await RelayClient.claimPairing(urlString: cleanURL, code: code)
            onPaired(client)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
