import SwiftUI

@main
struct FaceMetricsApp: App {
    @StateObject private var model = DashboardViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}
