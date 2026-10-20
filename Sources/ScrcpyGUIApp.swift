import SwiftUI

@main
struct ScrcpyGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DeviceManager.shared

    var body: some Scene {
        Window("Scrcpy GUI", id: "main") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 520, minHeight: 380)
        }
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Devices") { manager.refresh() }
                    .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running while mirrors are open, so closing the launcher window doesn't kill them.
        MainActor.assumeIsolated { DeviceManager.shared.running.isEmpty }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DeviceManager.shared.stopAll() }
    }
}
