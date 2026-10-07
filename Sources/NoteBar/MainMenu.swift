import AppKit

/// The main menu. NoteBar is an accessory app (no menu bar of its own is shown while another app is
/// active), but the menu still matters: AppKit routes key equivalents through it, so the Edit menu
/// makes ⌘Z / ⇧⌘Z / ⌘X / ⌘C / ⌘V / ⌘A work in the panel and in Settings with the standard selectors.
///
/// Shortcuts that the notes UI handles itself (⌘N, ⌘F, ⇧⌘M...) are deliberately not in this menu:
/// the panel's view hierarchy sees key equivalents first, and the menu must not shadow them elsewhere.
@MainActor
enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu(title: "Main Menu")

        // App menu.
        let app = NSMenu(title: "NoteBar")
        app.addItem(item("About NoteBar", #selector(AppDelegate.showAbout(_:)), "", target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettingsWindow(_:)), ",", target: target))
        app.addItem(item("Show / Hide Panel", #selector(AppDelegate.togglePanelFromMenu(_:)), "", target: target))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item("Quit NoteBar", #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)

        // Edit menu: standard selectors, sent to the first responder.
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        let redo = item("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        let plain = item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(plain)
        edit.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        add(edit, to: main)

        // Window menu.
        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(AppDelegate.closeKeyWindow(_:)), "w", target: target))
        add(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        main.addItem(holder)
    }
}
