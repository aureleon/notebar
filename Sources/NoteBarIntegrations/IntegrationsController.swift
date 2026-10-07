import AppKit
import NoteBarCore

// STUB — owned by the Integrations agent. Keep: IntegrationsController(env:), install()
@MainActor
public final class IntegrationsController {
    public init(env: AppEnvironment) {}
    /// Call from applicationWillFinishLaunching (URL Apple Event handler must be installed early).
    public func install() {}
}
