import AppKit
import NoteBarCore

/// The menu bar icon. Left click toggles the panel. Right-click, ⌃-click or ⌥-click opens the menu:
/// Show/Hide NoteBar, New Note, New Note from Clipboard, Search Notes, Keep Panel Open, Settings…, Quit.
///
/// The icon follows the panel side (sidebar.left / sidebar.right) and is filled while the panel is shown.
/// Shortcuts that could not be registered are listed in the menu with a warning.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    public let statusItem: NSStatusItem
    private let env: AppEnvironment
    private var observers: [NSObjectProtocol] = []
    private var panelVisible = false
    private var notifiedFailedHotkeys: [HotkeyAction] = []
    /// Optional: lets the menu list shortcuts that failed to register even if the registration
    /// notification was posted before this controller existed.
    public weak var hotkeyCenter: HotkeyCenter?

    private var failedHotkeys: [HotkeyAction] {
        if let hotkeyCenter { return HotkeyAction.allCases.filter { hotkeyCenter.failedActions.contains($0) } }
        return notifiedFailedHotkeys
    }

    public init(env: AppEnvironment) {
        self.env = env
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = "NoteBarStatusItem"
        statusItem.behavior = []          // not removable by ⌘-drag (it is the only way to quit an agent app)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("NoteBar")
        }
        panelVisible = env.controller?.isPanelVisible ?? false
        updateIcon()
        installObservers()
    }

    // MARK: Click

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let mods = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let wantsMenu = event?.type == .rightMouseUp || mods.contains(.option) || mods.contains(.control)
        if wantsMenu { showMenu() } else { env.controller?.togglePanel() }
    }

    /// Opens the menu under the icon (the standard way: attach temporarily, click, detach on close so
    /// left clicks keep toggling).
    public func showMenu() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
    }

    public func menuDidClose(_ menu: NSMenu) {
        // Detach after the click that opened it has finished.
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    func makeMenu() -> NSMenu {
        let s = env.settings
        let c = env.controller
        let menu = NSMenu(title: "NoteBar")
        menu.delegate = self
        menu.autoenablesItems = false
        let visible = c?.isPanelVisible ?? panelVisible

        let toggle = ClosureMenuItem(visible ? "Hide NoteBar" : "Show NoteBar") { c?.togglePanel() }
        toggle.nbShowHotkey(s.hotkeys[.togglePanel])
        menu.addItem(toggle)
        menu.addItem(.separator())

        let new = ClosureMenuItem("New Note") { c?.createNote(text: nil, folderName: nil, reveal: true) }
        new.nbShowHotkey(s.hotkeys[.newNote])
        menu.addItem(new)

        let clip = NSPasteboard.general.string(forType: .string)
        let fromClip = ClosureMenuItem("New Note from Clipboard", enabled: !(clip ?? "").isEmpty) {
            c?.createNote(text: NSPasteboard.general.string(forType: .string), folderName: nil, reveal: true)
        }
        fromClip.nbShowHotkey(s.hotkeys[.newNoteFromClipboard])
        menu.addItem(fromClip)

        let search = ClosureMenuItem("Search Notes") { c?.showSearch() }
        search.nbShowHotkey(s.hotkeys[.search])
        menu.addItem(search)
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Keep Panel Open", state: s.pinnedOpen ? .on : .off) { s.pinnedOpen.toggle() })
        let sideTitle = s.panelSide == .right ? "Move to Left Side" : "Move to Right Side"
        menu.addItem(ClosureMenuItem(sideTitle) { s.panelSide = s.panelSide.opposite })
        if !s.showOpenBar {
            menu.addItem(ClosureMenuItem("Show Open Bar") { s.showOpenBar = true })
        }

        if !failedHotkeys.isEmpty {
            menu.addItem(.separator())
            for action in failedHotkeys {
                let combo = s.hotkeys[action]?.displayString ?? ""
                let item = NSMenuItem(title: "Shortcut \(combo) for “\(action.displayName)” is unavailable", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", keyEquivalent: ",") { c?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit NoteBar", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
        return menu
    }

    // MARK: Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let side = env.settings.panelSide == .right ? "right" : "left"
        let name = panelVisible ? "sidebar.\(side).fill" : "sidebar.\(side)"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "NoteBar")
            ?? NSImage(systemSymbolName: "note.text", accessibilityDescription: "NoteBar")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        var tip = "NoteBar"
        if let combo = env.settings.hotkeys[.togglePanel] { tip += " (\(combo.displayString))" }
        tip += "\nClick to show or hide, right-click for the menu"
        button.toolTip = tip
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NoteBarPanelNotification.panelVisibilityDidChange, object: nil, queue: .main) { [weak self] n in
            let visible = (n.userInfo?["visible"] as? Bool) ?? false
            MainActor.assumeIsolated {
                self?.panelVisible = visible
                self?.updateIcon()
            }
        })
        observers.append(nc.addObserver(forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            guard key == nil || key == "panelSide" || key == "hotkeys" else { return }
            MainActor.assumeIsolated { self?.updateIcon() }
        })
        observers.append(nc.addObserver(forName: NoteBarPanelNotification.hotkeyRegistrationDidChange, object: nil, queue: .main) { [weak self] n in
            let failed = (n.userInfo?["failed"] as? [String]) ?? []
            let suspended = (n.userInfo?["suspended"] as? Bool) ?? false
            MainActor.assumeIsolated {
                guard let self, !suspended else { return }
                self.notifiedFailedHotkeys = HotkeyAction.allCases.filter { failed.contains($0.rawValue) }
            }
        })
    }
}
