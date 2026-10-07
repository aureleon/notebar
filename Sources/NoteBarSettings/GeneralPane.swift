import SwiftUI
import NoteBarCore

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launch: LaunchAtLoginModel

    private var widthBinding: Binding<Double> {
        Binding(get: { min(max(settings.panelWidth, 240), 520) },
                set: { v in
                    // Steps of 5 pt; only write real changes (every write moves the panel).
                    let w = min(max((v / 5).rounded() * 5, 240), 520)
                    if w != settings.panelWidth { settings.panelWidth = w }
                })
    }

    private var delayBinding: Binding<Double> {
        Binding(get: { min(max(settings.hotSideDelay, 0), 1.5) },
                set: { v in
                    let d = min(max((v * 20).rounded() / 20, 0), 1.5)
                    if d != settings.hotSideDelay { settings.hotSideDelay = d }
                })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { launch.isOn }, set: { launch.set($0) })) {
                    Text("Launch at login")
                    if let status = launch.statusText { Text(status) }
                }
                if launch.state == .requiresApproval {
                    HStack {
                        Spacer()
                        Button("Open Login Items Settings…") { LaunchAtLogin.openSystemSettings() }
                    }
                }
            }

            Section("Panel") {
                Picker("Screen edge", selection: $settings.panelSide) {
                    Text("Left").tag(PanelSide.left)
                    Text("Right").tag(PanelSide.right)
                }
                .pickerStyle(.segmented)

                LabeledContent("Width") {
                    HStack(spacing: 10) {
                        Slider(value: widthBinding, in: 240...520)
                            .frame(maxWidth: 220)
                        Text("\(Int(widthBinding.wrappedValue)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                Toggle(isOn: $settings.autoHide) {
                    Text("Hide when focus leaves")
                    Text("Slide the panel out when you click another app or window.")
                }
                .disabled(settings.pinnedOpen)

                Toggle(isOn: $settings.pinnedOpen) {
                    Text("Keep panel open")
                    Text("The panel stays visible until you hide it with the hotkey, the Open Bar or the menu bar icon.")
                }
            }

            Section("Opening") {
                Toggle(isOn: $settings.showOpenBar) {
                    Text("Show Open Bar")
                    Text("A thin tab on the screen edge. Click it to show or hide the panel. Right-click it to change sides.")
                }

                Toggle(isOn: $settings.hotSideEnabled) {
                    Text("Hot Side")
                    Text("Open the panel when the pointer rests on the screen edge.")
                }

                LabeledContent("Hot Side delay") {
                    HStack(spacing: 10) {
                        Slider(value: delayBinding, in: 0...1.5)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.2f s", delayBinding.wrappedValue))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!settings.hotSideEnabled)
            }
        }
        .formStyle(.grouped)
    }
}
