import SwiftUI

@main
struct TiloApp: App {
    @StateObject private var manager = PlayerManager()

    var body: some Scene {
        WindowGroup("Tilo") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("동영상 열기…") { manager.openVideos() }
                    .keyboardShortcut("o")
            }
        }
    }
}
