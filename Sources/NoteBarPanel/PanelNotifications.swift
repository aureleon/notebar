import Foundation

/// Notification names used by the panel module. Other modules (which cannot import NoteBarPanel) can
/// post / observe these with `Notification.Name("<raw value>")`.
public enum NoteBarPanelNotification {
    /// Posted by the Settings shortcut recorder. userInfo["active"] = Bool.
    /// While active, every global hotkey is unregistered so the recorder receives the keystroke.
    public static let hotkeyRecording = Notification.Name("NoteBar.hotkeyRecording")

    /// Posted by `HotkeyCenter` after every (re-)registration.
    /// userInfo["failed"] = [String] (HotkeyAction raw values that could not be registered,
    /// usually because another app owns the same shortcut).
    public static let hotkeyRegistrationDidChange = Notification.Name("NoteBar.hotkeyRegistrationDidChange")

    /// Post with userInfo["active"] = true before running UI that leaves the panel (for example an
    /// out-of-process picker), and with false afterwards. While at least one suspension is active the
    /// panel does not auto-hide. Calls are counted, so always balance them.
    public static let suspendAutoHide = Notification.Name("NoteBar.suspendAutoHide")

    /// Posted by `PanelController` when the panel shows or hides. userInfo["visible"] = Bool.
    public static let panelVisibilityDidChange = Notification.Name("NoteBar.panelVisibilityDidChange")
}
