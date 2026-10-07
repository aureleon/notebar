import SwiftUI
import NoteBarCore

struct AboutPane: View {
    let env: AppEnvironment

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

    private var stats: String {
        let folders = env.store.folders()
        let notes = folders.reduce(0) { $0 + env.store.noteCount(in: $1.id) }
        return "\(notes) note\(notes == 1 ? "" : "s") in \(folders.count) folder\(folders.count == 1 ? "" : "s")"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("NoteBar").font(.title).fontWeight(.semibold)
                    Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Notes in a panel on the edge of your screen.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                LabeledContent("Notes", value: stats)
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
