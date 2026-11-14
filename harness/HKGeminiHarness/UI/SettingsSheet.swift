import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var config = GeminiConfiguration()
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Proxy") {
                    TextField("https://your-host/gemini-proxy", text: $config.proxyBaseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Proxy access token (Bearer)", text: $token)
                    Text("The proxy holds the Gemini API key. The token here only authorises this app to the proxy; it is stored in the Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Model") {
                    TextField("Model ID", text: $config.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Thinking level", selection: $config.thinkingLevel) {
                        Text("low").tag("low"); Text("medium").tag("medium"); Text("high").tag("high")
                    }
                    Stepper("Timeout \(Int(config.timeoutSeconds)) s", value: $config.timeoutSeconds, in: 60...1800, step: 60)
                    Text("Default gemini-4-carbon (checked against Google's model list on 14 Nov 2026; paid tier). Change the ID here, no rebuild needed; the proxy can also pin a model with GEMINI_MODEL.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Validator") {
                    Toggle("Reject replies with numbers not in the payload", isOn: $config.validatorFailsOnUnsupportedNumbers)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        config.save()
                        state.gemini.configuration = config
                        state.gemini.proxyToken = token
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { config = state.gemini.configuration; token = state.gemini.proxyToken ?? "" }
        }
    }
}
