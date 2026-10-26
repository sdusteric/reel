import AppKit
import Observation
import ReelCore
import ReelUI
import SwiftUI

/// ReelCore's settings document (SwiftUI also has a `Settings` scene).
typealias ReelSettings = ReelCore.Settings

/// The settings (design 11.1), saved to `REEL_HOME/settings.json` on every change.
@Observable
final class SettingsModel {
    private(set) var settings: ReelSettings
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let log: ReelLog
    @ObservationIgnored var onChange: ((ReelSettings) -> Void)?

    init(store: SettingsStore, log: ReelLog) {
        self.store = store
        self.log = log
        settings = store.settings
    }

    func binding(_ keyPath: WritableKeyPath<ReelSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.set(keyPath, value) }
        )
    }

    private func set(_ keyPath: WritableKeyPath<ReelSettings, Bool>, _ value: Bool) {
        guard settings[keyPath: keyPath] != value else { return }
        do {
            try store.update { $0[keyPath: keyPath] = value }
        } catch {
            log.error("settings save failed: \(error)")
        }
        settings = store.settings
        onChange?(settings)
    }

    /// High dynamic range: Full, Limited or Off (section 11.1, D51).
    var highDynamicRange: Binding<HDRSetting> {
        Binding(
            get: { self.settings.highDynamicRange },
            set: { value in self.setHighDynamicRange(value) }
        )
    }

    func setHighDynamicRange(_ value: HDRSetting) {
        guard settings.highDynamicRange != value else { return }
        do {
            try store.update { $0.highDynamicRange = value }
        } catch {
            log.error("settings save failed: \(error)")
        }
        settings = store.settings
        onChange?(settings)
    }
}

/// Audio, Output Device and the Settings row (section 7.11, D67): the Core Audio device list and
/// the choice remembered in `state.json` by UID with its name.
@Observable
final class OutputDeviceModel {
    /// One entry of the menu and the popup.
    struct Entry: Hashable {
        var choice: OutputDeviceChoice
        var title: String
        /// "MacBook Pro Speakers" after System Default, in the secondary colour.
        var detail: String?
        var isSelected: Bool
        /// False for a chosen device that is unplugged; it stays listed so the choice is visible.
        var isConnected: Bool
    }

    private(set) var devices: [AudioOutputDevice] = []
    private(set) var choice: OutputDeviceChoice
    private(set) var resolution = OutputDeviceResolution(uid: nil, name: nil, isFallback: false)
    @ObservationIgnored private let stateStore: StateStore
    @ObservationIgnored private let list: () -> [AudioOutputDevice]
    @ObservationIgnored private let log: ReelLog
    /// Called with every resolution; `announce` is true when the chosen device just went missing
    /// (or a file opened while it is missing), so the OSD names the fallback once.
    @ObservationIgnored var onResolve: ((OutputDeviceResolution, _ announce: Bool) -> Void)?

    init(stateStore: StateStore, list: @escaping () -> [AudioOutputDevice], log: ReelLog) {
        self.stateStore = stateStore
        self.list = list
        self.log = log
        choice = stateStore.state.outputDevice
        devices = list()
        resolution = choice.resolve(against: devices)
    }

    /// The device list changed (the Core Audio listener) or a menu is about to show.
    func refresh() {
        devices = list()
        resolve()
    }

    func select(_ newChoice: OutputDeviceChoice) {
        guard newChoice != choice else { return }
        choice = newChoice
        do {
            try stateStore.update { $0.outputDevice = newChoice }
        } catch {
            log.error("output device save failed: \(error)")
        }
        resolve()
    }

    /// Re-reports the current resolution, e.g. when a file opens.
    func reapply() {
        onResolve?(resolution, resolution.isFallback)
    }

    private func resolve() {
        let previous = resolution
        resolution = choice.resolve(against: devices)
        log.info("audio output: \(resolution.name ?? "system default")\(resolution.isFallback ? " (chosen device missing)" : "")")
        onResolve?(resolution, resolution.isFallback && !previous.isFallback)
    }

    /// The name of the system default output device, when Core Audio reports one.
    var systemDefaultName: String? { devices.first(where: \.isDefault)?.name }

    /// System Default first, then every device, then a chosen device that is not connected.
    var entries: [Entry] {
        var result = [Entry(
            choice: .systemDefault,
            title: OutputDeviceChoice.systemDefaultTitle,
            detail: systemDefaultName,
            isSelected: choice == .systemDefault,
            isConnected: true
        )]
        for device in devices {
            result.append(Entry(
                choice: .device(uid: device.uid, name: device.name),
                title: device.name,
                isSelected: choice.uid == device.uid,
                isConnected: true
            ))
        }
        if case .device(let uid, let name) = choice, !devices.contains(where: { $0.uid == uid }) {
            result.append(Entry(choice: choice, title: name, detail: "Not connected", isSelected: true, isConnected: false))
        }
        return result
    }

    /// The popup's selection: a connected device's choice carries its current name.
    var selectedEntry: Entry? { entries.first(where: \.isSelected) }
}

/// One row of the Settings form (mockup png/27).
enum SettingsRow: Hashable {
    case toggle(String, detail: String?, WritableKeyPath<ReelSettings, Bool>)
    case highDynamicRange
    case outputDevice

    var title: String {
        switch self {
        case .toggle(let title, _, _): title
        case .highDynamicRange: "High dynamic range"
        case .outputDevice: "Output device"
        }
    }

    var detail: String? {
        switch self {
        case .toggle(_, let detail, _): detail
        case .highDynamicRange: HDRSetting.settingsExplanation
        case .outputDevice: OutputDeviceChoice.settingsExplanation
        }
    }
}

/// A heading and its rows.
struct SettingsSection: Identifiable {
    var title: String
    var rows: [SettingsRow]
    var id: String { title }

    /// Playback, Video and Audio (section 11.1, M3).
    static let all: [SettingsSection] = [
        SettingsSection(title: "Playback", rows: [
            .toggle("Resume playback where I left off", detail: nil, \.resumePlayback),
            .toggle("Show remaining time", detail: nil, \.showRemainingTime),
            .toggle("Show a keyframe preview while seeking", detail: nil, \.keyframePreview),
        ]),
        SettingsSection(title: "Video", rows: [
            .toggle("Hardware decoding", detail: "Off forces software decoding, for diagnosis.", \.hardwareDecoding),
            .highDynamicRange,
        ]),
        SettingsSection(title: "Audio", rows: [.outputDevice]),
    ]
}

struct SettingsView: View {
    let model: SettingsModel
    /// Nil only in previews; the app always passes the shared device model.
    var outputDevices: OutputDeviceModel?
    /// Nil when there is no updater (`REEL_NO_UPDATES=1`).
    var updates: UpdateSettingsModel?

    var body: some View {
        Form {
            ForEach(SettingsSection.all) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.self) { row in
                        rowView(row)
                    }
                }
            }
            if let updates {
                UpdatesSection(updates: updates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func rowView(_ row: SettingsRow) -> some View {
        switch row {
        case .toggle(_, _, let keyPath):
            Toggle(isOn: model.binding(keyPath)) { RowLabel(row: row) }
        case .highDynamicRange:
            Picker(selection: model.highDynamicRange) {
                ForEach(HDRSetting.allCases, id: \.self) { setting in
                    Text(setting.title).tag(setting)
                }
            } label: {
                RowLabel(row: row)
            }
            .pickerStyle(.menu)
        case .outputDevice:
            if let outputDevices {
                OutputDevicePicker(devices: outputDevices) { RowLabel(row: row) }
            }
        }
    }
}

/// The row title with its explanation under it at secondary weight.
private struct RowLabel: View {
    let row: SettingsRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            if let detail = row.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// System Default (with the default device's name in the secondary colour), a divider, then the
/// devices, as in png/27.
private struct OutputDevicePicker<Label: View>: View {
    let devices: OutputDeviceModel
    @ViewBuilder var label: () -> Label

    var body: some View {
        let entries = devices.entries
        Picker(selection: Binding(
            get: { devices.selectedEntry?.choice ?? .systemDefault },
            set: { devices.select($0) }
        )) {
            ForEach(entries.prefix(1), id: \.choice) { entry in
                entryText(entry).tag(entry.choice)
            }
            if entries.count > 1 {
                Divider()
                ForEach(entries.dropFirst(), id: \.choice) { entry in
                    entryText(entry).tag(entry.choice)
                }
            }
        } label: {
            label()
        }
        .pickerStyle(.menu)
    }

    private func entryText(_ entry: OutputDeviceModel.Entry) -> Text {
        guard let detail = entry.detail else { return Text(entry.title) }
        return Text("\(entry.title)  \(Text(detail).foregroundStyle(.secondary))")
    }
}

private struct UpdatesSection: View {
    @Bindable var updates: UpdateSettingsModel

    var body: some View {
        Section("Updates") {
            Toggle("Automatically install updates", isOn: $updates.automaticallyInstallsUpdates)
            HStack {
                Text("Reel checks once a day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates\u{2026}") { updates.checkForUpdates() }
            }
        }
    }
}

/// The Settings window, created on first use (Cmd+,).
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel, outputDevices: OutputDeviceModel?, updates: UpdateSettingsModel? = nil) {
        let hosting = NSHostingController(rootView: SettingsView(model: model, outputDevices: outputDevices, updates: updates))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
