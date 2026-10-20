import SwiftUI

@main
struct DeviceMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DeviceManager.shared

    var body: some Scene {
        Window("Device Mirror", id: "main") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 520, minHeight: 380)
        }
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Device Mirror") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Device Mirror",
                        .credits: NSAttributedString(string: "Mirrors Android screens with scrcpy and iPhone screens over USB."),
                    ])
                }
            }
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
        MainActor.assumeIsolated {
            DeviceManager.shared.stopAll()
            // Let any recording being finalized finish writing its file.
            let deadline = Date().addingTimeInterval(3)
            while IOSMirrorSession.pendingFinalizations > 0, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
    }
}
