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
