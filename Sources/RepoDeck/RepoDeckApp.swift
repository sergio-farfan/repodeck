import AppKit
import SwiftUI

@main
struct RepoDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var theme = ThemeSettings()

    var body: some Scene {
        WindowGroup(id: "main") {
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

                Button("Command Palette") {
                    model.isPaletteVisible = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        // Auto-adds the ⌘, "Settings…" menu item.
        Settings {
            SettingsView()
                .environment(model)
                .environment(theme)
                .environment(\.theme, Theme(settings: theme))
                // preferredColorScheme does not cross window boundaries, so
                // the Settings window must apply appearance/accent itself or
                // it won't reflect the very options it is editing.
                .preferredColorScheme(theme.appearance.colorScheme)
                .tint(theme.accent)
        }

        // Optional menu-bar presentation, toggleable in Settings ▸ General;
        // the full window (above) stays primary. Scenes don't inherit each
        // other's environment, so the chain is re-injected here too — same
        // reason the Settings scene does it. `preferredColorScheme` doesn't
        // cross into a menu-bar window meaningfully, so it's omitted; `\.theme`
        // + `theme` carry accent/fonts instead.
        MenuBarExtra(
            "RepoDeck",
            systemImage: "square.stack.3d.up.fill",
            isInserted: Binding(
                get: { model.isMenuBarExtraEnabled },
                set: { model.isMenuBarExtraEnabled = $0 }
            )
        ) {
            MenuBarContentView()
                .environment(model)
                .environment(theme)
                .environment(\.theme, Theme(settings: theme))
                .tint(theme.accent)
        }
        .menuBarExtraStyle(.window)
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
