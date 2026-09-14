import Foundation

enum AppResourceLocator {
    static func dockIconURL(in bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns") {
            return url
        }

        // A plain SwiftPM executable's bundleURL is already its directory.
        // Locate its sibling resource bundle from executableURL instead; an
        // app may also keep the resource bundle inside Contents/Resources.
        let resourceBundles = [
            bundle.executableURL?.deletingLastPathComponent(),
            bundle.resourceURL,
        ].compactMap { $0?.appendingPathComponent("RepoDeck_RepoDeck.bundle") }
        for candidate in resourceBundles {
            if let url = Bundle(url: candidate)?.url(forResource: "AppIcon", withExtension: "icns") {
                return url
            }
        }
        // Missing resources must not invoke Bundle.module's fatal fallback.
        return nil
    }
}
