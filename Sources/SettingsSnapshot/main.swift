import AppKit
import NoteBarCore
import NoteBarSettings

// Owned by the Settings agent. Render settings panes offscreen (no window on screen) to PNGs.
// Usage: swift run SettingsSnapshot /tmp/nb-settings
MainActor.assumeIsolated {
    _ = NSApplication.shared
    print("TODO: render settings panes")
}
