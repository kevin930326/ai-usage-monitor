import SwiftUI
import UsageKit

struct SettingsView: View {
    @Environment(UsageModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var testResult: TestResult?
    @State private var testing = false

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
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("測試連線")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(url.isEmpty || token.isEmpty || testing)

                    switch testResult {
                    case .success:
                        Label("連線成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    case nil:
                        EmptyView()
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
                        .disabled(url.isEmpty || token.isEmpty)
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
        if let error = await model.testConnection(url: url, token: token) {
            testResult = .failure(error)
        } else {
            testResult = .success
        }
    }

    private func save() {
        model.relayURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        model.readToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        Task { await model.refresh() }
    }
}
