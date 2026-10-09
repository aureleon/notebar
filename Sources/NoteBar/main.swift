import AppKit

MainActor.assumeIsolated {
    // Debug: `NoteBar --snapshot <dir>` renders the panel content offscreen to PNGs and exits.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot") {
        SnapshotMode.run(outputPath: i + 1 < args.count ? args[i + 1] : "notebar-snapshot")
    }
    // `NoteBar --readme-images <dir>` renders the README pictures (light and dark side by side) and exits.
    if let i = args.firstIndex(of: "--readme-images") {
        ReadmeImages.run(outputPath: i + 1 < args.count ? args[i + 1] : "docs/images")
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
