import SwiftUI

@main
struct SpeakitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(
                library: appState.library,
                player: appState.player,
                dictation: appState.dictation
            )
            .environmentObject(appState)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Voice Typing") {
                    appState.toggleDictation()
                }
                .keyboardShortcut("z", modifiers: [.option])
            }
        }

        Settings {
            SettingsView(player: appState.player, dictation: appState.dictation)
        }

        MenuBarExtra("Speakit", systemImage: "waveform.circle.fill") {
            MiniPlayerView(player: appState.player, dictation: appState.dictation)
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running from the menu bar when the last window closes, like
    /// other menu-bar productivity apps.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touch the shared state so hotkeys register even if SwiftUI defers
        // constructing any views.
        _ = AppState.shared
    }
}
