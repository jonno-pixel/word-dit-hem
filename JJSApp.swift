import SwiftUI

@main
@MainActor
struct JJSApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatScreen()
                .environmentObject(store)
                .onAppear { store.sceneChanged(scenePhase) }
                .onChange(of: scenePhase) { _, phase in store.sceneChanged(phase) }
                .onChange(of: store.isGenerating) { _, _ in store.sceneChanged(scenePhase) }
        }
    }
}
