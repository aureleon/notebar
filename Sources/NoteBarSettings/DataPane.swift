import SwiftUI
import NoteBarCore

struct DataPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var backups: BackupsModel

    private var retention: Binding<Int> {
        Binding(get: { min(max(settings.backupRetention, 1), 365) },
                set: { settings.backupRetention = min(max($0, 1), 365) })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.backupsEnabled) {
                    Text("Automatic backups")
                    Text("Once a day, NoteBar saves the notes database and attachments as a zip file.")
                }

                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(retention.wrappedValue) backup\(retention.wrappedValue == 1 ? "" : "s")")
                            .monospacedDigit()
                        Stepper("Keep the last", value: retention, in: 1...365)
                            .labelsHidden()
                    }
                } label: {
                    Text("Keep the last")
                    Text("Older backups are deleted automatically.")
                }
                .disabled(!settings.backupsEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backups.lastBackupText)
                        if let message = backups.statusMessage {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if backups.isWorking { ProgressView().controlSize(.small) }
                    Button("Back Up Now") { backups.backUpNow() }
                        .disabled(backups.isWorking)
                }
            } header: {
                Text("Backups")
            } footer: {
                if !backups.isAvailable {
                    FootnoteText("Backups are not available in this build.")
                }
                ForEach([backups.saveProblem, backups.backupProblem].compactMap { $0 }, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!backups.isAvailable)

            Section {
                Picker(selection: $settings.deletedItemsRetention) {
                    ForEach(DeletedItemsRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    Text("Keep deleted items")
                    Text("Until then, ⌘Z or the Undo button brings a deleted note or folder back.")
                }
            } header: {
                Text("Deleted Notes")
            } footer: {
                FootnoteText(settings.deletedItemsRetention == .recentlyDeleted
                             ? "Deleted notes and folders are listed in Recently Deleted at the bottom of the folder list."
                             : "After that time, deleted notes and folders are removed for good. A change applies from now on.")
            }

            Section("Files") {
                LabeledContent {
                    Button("Open Data Folder") { backups.openDataFolder() }
                } label: {
                    Text("Data folder")
                    Text(SettingsFormat.abbreviatedPath(AppPaths.supportDirectory))
                        .textSelection(.enabled)
                }

                LabeledContent {
                    Button("Open Backups Folder") { backups.openBackupsFolder() }
                } label: {
                    Text("Backups folder")
                    Text(SettingsFormat.abbreviatedPath(AppPaths.backupsDirectory))
                        .textSelection(.enabled)
                }

                LabeledContent {
                    Button("Export All as Markdown…") { backups.exportAllAsMarkdown() }
                        .disabled(!backups.isAvailable || backups.isWorking)
                } label: {
                    Text("Export")
                    Text("One Markdown file per note, one folder per NoteBar folder.")
                }
            }

            Section {
                if backups.backups.isEmpty {
                    Text(backups.isAvailable ? "No backups yet." : "Backups are not available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(backups.backups.enumerated()), id: \.element.id) { index, info in
                        BackupRow(info: info, isLatest: index == 0, isWorking: backups.isWorking,
                                  restore: { backups.confirmRestore(info) },
                                  reveal: { backups.reveal(info) })
                    }
                }
            } header: {
                HStack {
                    Text("Restore from Backup")
                    Spacer()
                    if let total = backups.totalSizeText {
                        Text(total).font(.callout).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            } footer: {
                if backups.isAvailable {
                    FootnoteText("Before a restore, NoteBar makes a safety backup of your current notes.")
                }
            }
            .disabled(!backups.isAvailable)
        }
        .formStyle(.grouped)
    }
}

private struct BackupRow: View {
    let info: BackupInfo
    let isLatest: Bool
    let isWorking: Bool
    let restore: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(SettingsFormat.backupDate.string(from: info.date))
                    if isLatest {
                        Text("Latest")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                Text(SettingsFormat.bytes(info.sizeBytes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: reveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button("Restore…", action: restore)
                .disabled(isWorking)
        }
        .contextMenu {
            Button("Restore…", action: restore)
            Button("Show in Finder", action: reveal)
        }
    }
}
