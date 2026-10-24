import SwiftUI
import UsageKit
import UsageKitUI

struct SettingsView: View {
    @Environment(UsageModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var saveError: String?
    @State private var scanning = false
    @State private var enteringCode = false
    /// 掃到、等使用者確認的配對內容（確認畫面只顯示主機名稱）
    @State private var pendingPairing: PairingPayload?
    /// 掃描畫面關閉後才顯示確認（sheet 關閉動畫中無法顯示 alert）
    @State private var scanned: PairingPayload?
    @State private var paired = false
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system.rawValue

    // 貼上的值常帶前後空白或換行，判斷、測試與儲存都用去除後的值
    private var cleanURL: String { RelayInput.clean(url) }
    private var cleanToken: String { RelayInput.clean(token) }

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ai-usage-relay.帳號.workers.dev", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("讀取密鑰（READ_TOKEN）", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("中繼 API")
                } footer: {
                    Text("密鑰只存在這台 iPhone 的 Keychain。請使用讀取密鑰，不要填寫入密鑰。")
                }

                // iPhone 配對（ADR-0012）：掃 Mac 終端機的 QR 碼，或輸入一次性短碼
                Section {
                    Button { scanning = true } label: { Label("掃描 QR 碼", systemImage: "qrcode.viewfinder") }
                        .disabled(!PairingScannerSheet.isAvailable)
                    Button { enteringCode = true } label: { Label("輸入短碼", systemImage: "number") }
                    if paired {
                        Label("已配對，正在更新", systemImage: "checkmark.circle.fill")
                    }
                } header: {
                    Text("從 Mac 配對")
                } footer: {
                    Text(PairingScannerSheet.isAvailable
                         ? "在 Mac 執行 scripts/setup-iphone.sh --pair qr，掃描終端機上的 QR 碼；會自動填好網址與讀取密鑰。"
                         : "這台裝置不能掃描 QR 碼（需要相機）。可以改用短碼或手動填寫。")
                }

                Section {
                    Picker("顯示", selection: Bindable(model).displayMode) {
                        ForEach(UsageDisplayMode.allCases, id: \.self) { Text("\($0.label) %").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("百分比")
                } footer: {
                    Text("App 與 Live Activity 都會依此顯示已用或剩餘的百分比。")
                }

                Section {
                    Picker("外觀", selection: Binding(
                        get: { AppearanceChoice(stored: appearance) }, set: { appearance = $0.rawValue }
                    )) {
                        ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("外觀")
                } footer: {
                    Text("只套用到 App 本身。小工具與即時動態跟隨系統。")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("測試連線")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(cleanURL.isEmpty || cleanToken.isEmpty || testing)

                    switch testResult {
                    case .success:
                        Label("連線成功", systemImage: "checkmark.circle.fill")
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill").foregroundStyle(UsageColors.notice)
                    case nil:
                        EmptyView()
                    }
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "xmark.circle.fill").foregroundStyle(UsageColors.notice)
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                        .disabled(cleanURL.isEmpty || cleanToken.isEmpty)
                }
            }
            .onAppear {
                url = model.relayURL
                token = model.readToken
            }
            .sheet(isPresented: $scanning, onDismiss: {
                pendingPairing = scanned
                scanned = nil
            }) {
                PairingScannerSheet { scanned = $0 }
            }
            .sheet(isPresented: $enteringCode) {
                PairingCodeSheet(initialURL: cleanURL) { client in
                    apply(url: client.baseURL.absoluteString, token: client.readToken)
                }
            }
            .alert(pendingPairing.map { "把中繼設定為 \($0.host)？" } ?? "", isPresented: Binding(
                get: { pendingPairing != nil }, set: { if !$0 { pendingPairing = nil } }
            ), presenting: pendingPairing) { payload in
                Button(model.isConfigured ? "取代目前的設定" : "設定") {
                    apply(url: payload.url.absoluteString, token: payload.readToken)
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("會存下這個中繼的網址與讀取密鑰（密鑰不會顯示）。")
            }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        if let error = await model.testConnection(url: cleanURL, token: cleanToken) {
            testResult = .failure(error)
        } else {
            testResult = .success
        }
    }

    /// 配對成功：與手動儲存相同（網址存 UserDefaults、密鑰存 Keychain），立即更新一次
    private func apply(url newURL: String, token newToken: String) {
        do {
            try model.saveSettings(url: newURL, token: newToken)
        } catch {
            saveError = error.localizedDescription
            return
        }
        url = newURL
        token = newToken
        saveError = nil
        testResult = nil
        paired = true
        Task { await model.refresh() }
    }

    private func save() {
        do {
            try model.saveSettings(url: cleanURL, token: cleanToken)
        } catch {
            // 沒存成功就留在設定畫面，舊密鑰仍可用
            saveError = error.localizedDescription
            return
        }
        dismiss()
        Task { await model.refresh() }
    }
}
