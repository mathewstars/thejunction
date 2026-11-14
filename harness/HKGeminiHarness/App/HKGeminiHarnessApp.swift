import SwiftUI

@main
struct HKGeminiHarnessApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
    }
}

/// Four developer screens. Consent and errors are shown over whichever tab is active.
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            HealthKitScreen()
                .tabItem { Label("HealthKit", systemImage: "heart.text.square") }
            ARKitImportScreen()
                .tabItem { Label("ARKit Import", systemImage: "faceid") }
            GeminiExperimentsScreen()
                .tabItem { Label("Gemini", systemImage: "sparkles") }
            CombinedDatasetScreen()
                .tabItem { Label("Combined", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .sheet(item: $state.pendingRequest) { req in
            ConsentSheet(request: req)
                .environmentObject(state)
        }
        .alert("Error", isPresented: Binding(get: { state.lastError != nil }, set: { if !$0 { state.lastError = nil } })) {
            Button("OK", role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .overlay(alignment: .top) {
            if let b = state.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(b).font(.footnote.monospaced())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 4)
            }
        }
    }
}
