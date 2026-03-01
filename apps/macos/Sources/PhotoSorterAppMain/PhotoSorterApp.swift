import AppKit
import SwiftUI
import PhotoSorterUI

final class PhotoSorterAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        ProcessInfo.processInfo.processName = String(localized: "Photo Sorter", bundle: .appResources)
        app.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PhotoSorterApp: App {
    @NSApplicationDelegateAdaptor(PhotoSorterAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    private func showAboutPanel() {
        let credits = NSAttributedString(string: String(localized: "Author: chenshengyi", bundle: .appResources))
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    var body: some Scene {
        WindowGroup("Photo Sorter") {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Photo Sorter") {
                    showAboutPanel()
                }
            }
        }
    }
}
