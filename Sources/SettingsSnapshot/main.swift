import AppKit
import NoteBarCore
import NoteBarSettings

// Renders the settings panes offscreen (no window is shown on screen) to PNG files and runs a few
// behavior checks (shortcut recorder, launch agent plist, window wiring).
// Usage: swift run SettingsSnapshot /tmp/nb-settings

@MainActor
final class FakeBackups: BackupService {
    var list: [BackupInfo]
    var restored: [BackupInfo] = []

    init() {
        let dir = URL(fileURLWithPath: "/tmp/NoteBar-fake/Backups", isDirectory: true)
        let now = Date()
        list = (0..<6).map { i in
            let d = now.addingTimeInterval(-Double(i) * 86_400 - 3_600)
            return BackupInfo(url: dir.appendingPathComponent("NoteBar-\(i).zip"), date: d,
                              sizeBytes: Int64(1_250_000 + i * 37_000))
        }
    }

    func backupNow() throws -> BackupInfo {
        let b = BackupInfo(url: URL(fileURLWithPath: "/tmp/NoteBar-fake/Backups/now.zip"), date: Date(), sizeBytes: 1_300_000)
        list.insert(b, at: 0)
        return b
    }
    func backups() -> [BackupInfo] { list }
    func restore(_ backup: BackupInfo) throws { restored.append(backup) }
    func performDailyBackupIfNeeded() {}
    func exportAllAsMarkdown(to directory: URL) throws {}
}

@MainActor
func pump(_ seconds: TimeInterval = 0.15) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func render(_ view: NSView, appearance: NSAppearance, to url: URL) {
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.backgroundColor = .windowBackgroundColor
    window.contentView = view
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    pump(0.3)
    view.layoutSubtreeIfNeeded()
    view.display()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("no rep for \(url.lastPathComponent)"); return }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("wrote \(url.path)")
    }
    window.contentView = nil
}

@MainActor
func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: chars,
                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

@MainActor
func checkRecorder() {
    ShortcutRecorderView.beepsOnInvalidKey = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let recorder = ShortcutRecorderView(frame: NSRect(x: 20, y: 18, width: 160, height: 24))
    window.contentView?.addSubview(recorder)
    var states: [Bool] = []
    let token = NotificationCenter.default.addObserver(forName: Notification.Name("NoteBar.hotkeyRecording"), object: nil, queue: nil) { n in
        if let a = n.userInfo?["active"] as? Bool { states.append(a) }
    }
    var changes: [KeyCombo?] = []
    recorder.onChange = { changes.append($0) }
    recorder.combo = HotkeyAction.defaults[.togglePanel]

    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 60, y: 30), modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    recorder.mouseDown(with: down)
    Check.expect(recorder.isRecording, "click starts recording")
    Check.equal(states, [true], "posts active=true")
    Check.expect(window.firstResponder === recorder, "recorder is first responder")

    recorder.keyDown(with: key(0x00, "A", [.shift], window: window))
    Check.expect(recorder.isRecording, "⇧A alone is rejected, still recording")
    Check.expect(changes.isEmpty, "no change for ⇧A")

    _ = recorder.performKeyEquivalent(with: key(0x28, "k", [.command, .option], window: window))
    Check.expect(!recorder.isRecording, "⌥⌘K stops recording")
    Check.equal(recorder.combo, KeyCombo(keyCode: 0x28, carbonModifiers: KeyCombo.cmd | KeyCombo.option), "⌥⌘K recorded")
    Check.equal(changes.count, 1, "onChange called once")
    Check.equal(recorder.combo?.displayString ?? "", "⌥⌘K", "display string")
    Check.equal(states, [true, false], "posts active=false")

    recorder.startRecording()
    recorder.keyDown(with: key(0x35, "\u{1b}", [], window: window))
    Check.expect(!recorder.isRecording, "Esc cancels")
    Check.equal(recorder.combo?.keyCode ?? 0, 0x28, "Esc keeps the old shortcut")
    Check.equal(changes.count, 1, "Esc does not call onChange")

    recorder.startRecording()
    recorder.keyDown(with: key(0x02, "d", [.control, .shift], window: window))
    Check.equal(recorder.combo, KeyCombo(keyCode: 0x02, carbonModifiers: KeyCombo.control | KeyCombo.shift), "⌃⇧D recorded via keyDown")

    recorder.startRecording()
    recorder.keyDown(with: key(0x33, "\u{7f}", [], window: window))
    Check.expect(recorder.combo == nil, "⌫ clears")
    Check.expect(changes.last! == nil, "onChange(nil) on clear")
    Check.expect(!recorder.isRecording, "⌫ stops recording")

    recorder.combo = HotkeyAction.defaults[.search]
    recorder.startRecording()
    window.makeFirstResponder(nil)
    Check.expect(!recorder.isRecording, "losing focus stops recording")
    recorder.startRecording()
    recorder.removeFromSuperview()
    Check.expect(!recorder.isRecording, "removal stops recording")
    Check.equal(states.filter { $0 }.count, states.filter { !$0 }.count, "active true/false notifications are balanced")
    NotificationCenter.default.removeObserver(token)
    window.close()
}

@MainActor
func checkLaunchAgentPlist() {
    do {
        let data = try LaunchAtLogin.makeLaunchAgentPlist(executablePath: "/Applications/NoteBar.app/Contents/MacOS/NoteBar",
                                                          bundleIdentifier: "local.dhguz.NoteBar")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        Check.equal(plist?["Label"] as? String, "local.dhguz.NoteBar", "label")
        Check.equal(plist?["ProgramArguments"] as? [String], ["/Applications/NoteBar.app/Contents/MacOS/NoteBar"], "program")
        Check.equal(plist?["RunAtLoad"] as? Bool, true, "RunAtLoad")
        Check.expect(LaunchAtLogin.launchAgentURL.path.hasSuffix("Library/LaunchAgents/local.dhguz.NoteBar.plist"), "agent path")
        print("launch at login state (read only): \(LaunchAtLogin.state)")
    } catch {
        Check.expect(false, "plist: \(error)")
    }
}

@MainActor
func renderAll(_ models: SettingsModels, outDir: URL, tall: Bool, suffix: String = "", tabs: [SettingsTab] = SettingsTab.allCases) {
    let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
    for tab in tabs {
        for (name, ap) in [("light", light), ("dark", dark)] {
            let v = SettingsViews.makeHostingView(for: tab, models: models)
            if tall { v.frame.size.height = 1500 }
            render(v, appearance: ap, to: outDir.appendingPathComponent("\(tab.rawValue)\(suffix)-\(name).png"))
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/nb-settings", isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let suite = "local.dhguz.NoteBar.SettingsSnapshot"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: defaults)
    let store = InMemoryNoteStore(seed: true)
    let themes = ThemeManager(settings: settings, store: store)
    let backups = FakeBackups()
    let env = AppEnvironment(store: store, backups: backups, settings: settings, themes: themes,
                             editorFactory: PlainNoteEditorFactory())

    checkRecorder()
    checkLaunchAgentPlist()

    // A duplicate shortcut, to show the warning.
    settings.hotkeys[.search] = settings.hotkeys[.togglePanel]

    let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
    let tall = CommandLine.arguments.contains("--tall")

    let models = SettingsModels(env: env)
    renderAll(models, outDir: outDir, tall: tall)

    // Custom theme selected: the theme editor is visible.
    var custom = Theme.defaultTheme
    custom.id = "custom-snapshot"; custom.name = "My Theme"; custom.light.accent = "#D9480F"
    store.saveTheme(custom)
    settings.themeId = custom.id
    models.refresh()
    Check.equal(themes.theme.id, "custom-snapshot", "ThemeManager picked the custom theme")
    renderAll(models, outDir: outDir, tall: tall, suffix: "-custom", tabs: [.appearance])
    settings.themeId = "default"

    // No backup service.
    let envNoBackups = AppEnvironment(store: store, backups: nil, settings: settings, themes: themes,
                                      editorFactory: PlainNoteEditorFactory())
    renderAll(SettingsModels(env: envNoBackups), outDir: outDir, tall: tall, suffix: "-nobackups", tabs: [.data])

    // The real window (never ordered on screen): check wiring and render it with its toolbar.
    let controller = SettingsWindowController(env: env)
    let w = controller.window
    Check.equal(w.toolbar?.items.count ?? 0, SettingsTab.allCases.count, "toolbar has one item per tab")
    controller.select(.shortcuts)
    pump()
    Check.equal(w.title, "Shortcuts", "window title follows the tab")
    Check.equal(w.contentRect(forFrameRect: w.frame).size, SettingsTab.shortcuts.contentSize, "window resized to the tab")
    Check.expect(!w.isVisible, "window is not on screen")
    if let frameView = w.contentView?.superview {
        for (name, ap) in [("light", light), ("dark", dark)] {
            w.appearance = ap
            controller.select(.general)
            pump(0.3)
            frameView.layoutSubtreeIfNeeded()
            if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let url = outDir.appendingPathComponent("window-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }

    UserDefaults().removePersistentDomain(forName: suite)
    Check.finish()
}
