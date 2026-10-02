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
                // Control-surface layouts (pads, faders, toolbars) are sized like hardware; let text grow
                // one step past the default, not enough to push rows off the screen.
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
