import AppKit
import Observation
import ReelCore
import ReelUI
import SwiftUI

/// ReelCore's settings document (SwiftUI also has a `Settings` scene).
typealias ReelSettings = ReelCore.Settings

/// The four settings (design 11.1), saved to `REEL_HOME/settings.json` on every change.
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
}

struct SettingsView: View {
    let model: SettingsModel
    /// Nil when there is no updater (`REEL_NO_UPDATES=1`).
    var updates: UpdateSettingsModel?

    var body: some View {
        Form {
            Section {
                Toggle("Resume playback where I left off", isOn: model.binding(\.resumePlayback))
                Toggle("Show remaining time", isOn: model.binding(\.showRemainingTime))
                Toggle("Show a keyframe preview while seeking", isOn: model.binding(\.keyframePreview))
            }
            Section {
                Toggle("Hardware decoding", isOn: model.binding(\.hardwareDecoding))
                Text("Turn off to decode in software, for diagnosis. Decoder and preview changes apply to the next file you open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let updates {
                UpdatesSection(updates: updates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdatesSection: View {
    @Bindable var updates: UpdateSettingsModel

    var body: some View {
        Section {
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
    init(model: SettingsModel, updates: UpdateSettingsModel? = nil) {
        let hosting = NSHostingController(rootView: SettingsView(model: model, updates: updates))
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
