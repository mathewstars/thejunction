import SwiftUI

/// Shown before every transmission. Lists exactly what leaves the phone: categories, time range,
/// payload size, destination and model. Raw video, geometry and identifiers are never in the payload;
/// the sheet says so, and the payload itself can be inspected before accepting.
struct ConsentSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: GeminiAnalysisRequest
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            List {
                Section("About to send") {
                    KV("Experiment", request.experiment.title)
                    KV("Model", request.model)
                    KV("Via proxy", state.gemini.configuration.proxyBaseURL.isEmpty ? "(not set)" : state.gemini.configuration.proxyBaseURL)
                    KV("Payload size", Fmt.bytes(request.payloadBytes))
                    if let r = request.inputDataRange {
                        KV("Data from", r.start)
                        KV("Data to", r.end)
                    } else {
                        KV("Data range", "none (no measurements)")
                    }
                }
                Section("Data categories in the payload") {
                    if request.dataCategories.isEmpty { Text("No measurement data.").foregroundStyle(.secondary) }
                    ForEach(request.dataCategories, id: \.self) { Text($0) }
                }
                Section("Never transmitted") {
                    Label("Camera frames or video", systemImage: "video.slash")
                    Label("Face mesh vertices (geometry)", systemImage: "cube.transparent")
                    Label("Raw per-frame ARKit rows", systemImage: "tablecells")
                    Label("Names, participant labels, notes, device identifiers", systemImage: "person.crop.circle.badge.xmark")
                    Label("The Gemini API key (stays on the proxy)", systemImage: "key")
                }
                Section {
                    NavigationLink("Inspect the exact payload JSON") { JSONView(title: "Payload", json: request.payload) }
                    NavigationLink("Inspect the prompt") {
                        ScrollView { Text(request.systemInstruction + "\n\n---\n\n" + request.userPrompt).font(.footnote).textSelection(.enabled).padding() }
                            .navigationTitle("Prompt")
                    }
                }
                Section {
                    Toggle("I understand this summary is sent to Google's Gemini API through our proxy and may be processed outside the device.", isOn: $acknowledged)
                        .font(.footnote)
                }
            }
            .navigationTitle("Consent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { state.pendingRequest = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        dismiss()
                        Task { await state.sendPending() }
                    }
                    .disabled(!acknowledged)
                }
            }
        }
    }
}
