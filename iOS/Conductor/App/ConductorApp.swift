import SwiftUI

@main
struct ConductorApp: App {
    @State private var store = LiveStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
