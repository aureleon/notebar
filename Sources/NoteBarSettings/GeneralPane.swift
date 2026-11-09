import SwiftUI
import NoteBarCore

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launch: LaunchAtLoginModel

    /// Width the automatic rule gives for the current main screen.
    private var automaticWidth: CGFloat {
        PanelWidth.automatic(visibleWidth: NSScreen.main?.visibleFrame.width ?? 0)
    }

    /// The width the panel uses now (automatic or fixed), within the limits.
    private var effectiveWidth: CGFloat {
        if settings.panelWidthIsAutomatic { return automaticWidth }
        return min(max(CGFloat(settings.panelWidth), PanelWidth.minWidth), PanelWidth.maxWidth)
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(effectiveWidth) },
                set: { v in
                    // Steps of 5 pt. Moving the slider makes the width fixed.
                    let w = min(max((v / 5).rounded() * 5, PanelWidth.minWidth), PanelWidth.maxWidth)
                    if settings.panelWidthIsAutomatic { settings.panelWidthIsAutomatic = false }
                    if w != settings.panelWidth { settings.panelWidth = Double(w) }
                })
    }

    private var delayBinding: Binding<Double> {
        Binding(get: { min(max(settings.hotSideDelay, 0), 1.5) },
                set: { v in
                    let d = min(max((v * 20).rounded() / 20, 0), 1.5)
                    if d != settings.hotSideDelay { settings.hotSideDelay = d }
                })
    }

    private var keepDaysBinding: Binding<Int> {
        Binding(get: { ScratchService.clampKeepDays(settings.scratchKeepDays) },
                set: { v in
                    let d = ScratchService.clampKeepDays(v)
                    if d != settings.scratchKeepDays { settings.scratchKeepDays = d }
                })
    }

    /// "Midnight", "1 AM" … in the user's clock style.
    static func hourName(_ h: Int) -> String {
        if h == 0 { return "Midnight" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return f.string(from: d)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { launch.isOn }, set: { launch.set($0) })) {
                    Text("Launch at login")
                    if let status = launch.statusText { Text(status) }
                }
                if launch.showsLoginItemsButton {
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
                        Slider(value: widthBinding, in: Double(PanelWidth.minWidth)...Double(PanelWidth.maxWidth))
                            .frame(maxWidth: 200)
                        Text(settings.panelWidthIsAutomatic
                             ? "Automatic (\(Int(automaticWidth)) pt)"
                             : "\(Int(effectiveWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Button("Default") { settings.panelWidthIsAutomatic = true }
                            .disabled(settings.panelWidthIsAutomatic)
                    }
                }

                Toggle(isOn: $settings.autoHide) {
                    Text("Hide when focus leaves")
                    Text("Slide the panel out when you click another app or window.")
                }
                .disabled(settings.pinnedOpen)

                Toggle(isOn: $settings.pinnedOpen) {
                    Text("Float / Stay open")
                    Text("The panel stays visible while you work in other apps.")
                }
            }

            Section("Opening") {
                Toggle(isOn: $settings.hotSideEnabled) {
                    Text("Swipe to edge")
                    Text("Open the panel when the pointer rests on the screen edge.")
                }
                .toggleStyle(.checkbox)

                Picker("Active area", selection: $settings.hotSideArea) {
                    Text("Corner").tag(HotSideArea.corner)
                    Text("Quadrant").tag(HotSideArea.quadrant)
                    Text("Edge").tag(HotSideArea.edge)
                    Text("Dynamic").tag(HotSideArea.dynamic)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.hotSideEnabled)

                Text(settings.hotSideArea.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Swipe to edge delay") {
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

            Section {
                Toggle(isOn: $settings.scratchEnabled) {
                    Text("Daily Scratch note")
                    Text("A throwaway note that starts empty every day. Earlier days stay readable for a while; "
                         + "save what you want to keep as a note.")
                }

                LabeledContent("Keep earlier days") {
                    Stepper(value: keepDaysBinding, in: ScratchService.keepDaysRange) {
                        Text(keepDaysBinding.wrappedValue == 1 ? "1 day" : "\(keepDaysBinding.wrappedValue) days")
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                .disabled(!settings.scratchEnabled)

                Picker("New day starts at", selection: $settings.scratchRolloverHour) {
                    ForEach(0..<24, id: \.self) { h in Text(Self.hourName(h)).tag(h) }
                }
                .disabled(!settings.scratchEnabled)
            } header: {
                Text("Scratch")
            } footer: {
                FootnoteText("Older days go to Recently Deleted as normal notes, headed with their date "
                             + "(Data › Keep deleted items sets how long they stay there).")
            }
        }
        .formStyle(.grouped)
    }
}
