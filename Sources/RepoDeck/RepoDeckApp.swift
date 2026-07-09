import AppKit
import SwiftUI

@main
struct RepoDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var theme = ThemeSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(theme)
                .environment(\.theme, Theme(settings: theme))
                .preferredColorScheme(theme.appearance.colorScheme)
                .tint(theme.accent)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Repositories") {
                    Task { await model.rescan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // Auto-adds the ⌘, "Settings…" menu item.
        Settings {
            SettingsView()
                .environment(theme)
                .environment(\.theme, Theme(settings: theme))
                // preferredColorScheme does not cross window boundaries, so
                // the Settings window must apply appearance/accent itself or
                // it won't reflect the very options it is editing.
                .preferredColorScheme(theme.appearance.colorScheme)
                .tint(theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
}
