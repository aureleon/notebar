import AppKit
import NoteBarCore

// STUB — owned by the Panel agent. Keep these public entry points:
//   PanelController(env:), setContent(_:), show(animated:), hide(animated:), toggle(), isVisible
//   HotkeyCenter(settings:), onAction
//   StatusItemController(env:)
@MainActor
public final class PanelController {
    public init(env: AppEnvironment) {}
    public private(set) var isVisible = false
    public func setContent(_ viewController: NSViewController) {}
    public func show(animated: Bool = true) {}
    public func hide(animated: Bool = true) {}
    public func toggle() { isVisible ? hide() : show() }
}

@MainActor
public final class HotkeyCenter {
    public var onAction: ((HotkeyAction) -> Void)?
    public init(settings: AppSettings) {}
}

@MainActor
public final class StatusItemController {
    public init(env: AppEnvironment) {}
}
