import SwiftUI

/// Fish Pocket on the wrist: what the agent on the phone is doing, the answer it
/// is waiting for, and a tap when it is done. The engine stays on the phone.
@main
struct DshWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack { HomeView() }
                .environment(model)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.send(.refresh) }
        }
    }
}
