import SwiftUI
import NoteBarCore

/// Note/folder counts for the About pane, kept current while the window is open.
@MainActor
final class AboutModel: ObservableObject {
    private let store: NoteStore
    @Published private(set) var stats = ""
    private var observer: NSObjectProtocol?

    init(store: NoteStore) {
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: .noteStoreDidChange, object: nil, queue: .main) { [weak self] n in
            switch n.storeChange {
            case .folders?, .notes?, .all?, nil: MainActor.assumeIsolated { self?.refresh() }
            default: break
            }
        }
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {
        let folders = store.folders()
        let notes = folders.reduce(0) { $0 + store.noteCount(in: $1.id) }
        let s = "\(notes) note\(notes == 1 ? "" : "s") in \(folders.count) folder\(folders.count == 1 ? "" : "s")"
        if s != stats { stats = s }
    }
}

struct AboutPane: View {
    let env: AppEnvironment
    @ObservedObject var about: AboutModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "Version \(s) (\(b))"
        case let (s?, _): return "Version \(s)"
        default: return "Development build"
        }
    }

    /// The app icon inside a real bundle; a symbol for bare dev executables (they get a folder icon).
    private var icon: some View {
        Group {
            if Bundle.main.bundleURL.pathExtension == "app", let image = NSApp.applicationIconImage {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "note.text")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: "#F0B456"), Color(hex: "#E08A1E")],
                                             startPoint: .top, endPoint: .bottom)))
            }
        }
        .frame(width: 88, height: 88)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    icon
                    Text("NoteBar").font(.title).fontWeight(.semibold)
                    Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Notes in a panel on the edge of your screen.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                LabeledContent("Notes", value: about.stats)
                LabeledContent {
                    Button("Show in Finder") {
                        AppPaths.ensureDirectories()
                        NSWorkspace.shared.open(AppPaths.supportDirectory)
                    }
                } label: {
                    Text("Data folder")
                    Text(AppPaths.supportDirectory.path).textSelection(.enabled)
                }
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Database")
                    Text(AppPaths.databaseURL.path).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
