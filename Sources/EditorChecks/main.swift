import AppKit
import NoteBarCore
import NoteBarEditor

// Owned by the Editor agent.
//   swift run EditorChecks                       — unit + behavior checks
//   swift run EditorChecks --snapshot <dir>      — also renders offscreen PNG snapshots into <dir>
let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    // Never put a dialog on the screen: an unexpected one is a failed check, answered Cancel.
    ModalSupport.testResponder = { title in
        Check.expect(false, "unexpected dialog: \(title)")
        return .cancel
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    CodecChecks.run()
    SyntaxChecks.run()
    FormatChecks.run()
    ListChecks.run()
    BehaviorChecks.run()
    PolishChecks.run()
    VimChecks.run()
    CodeBlockChecks.run()
    PerfChecks.run(verbose: arguments.contains("--perf"))

    if let i = arguments.firstIndex(of: "--snapshot") {
        let dir = i + 1 < arguments.count ? arguments[i + 1] : "/tmp/nb-editor"
        Snapshots.run(outputDirectory: URL(fileURLWithPath: dir, isDirectory: true))
    }
}
Check.finish()
