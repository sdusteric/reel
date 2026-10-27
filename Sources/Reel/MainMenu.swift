import AppKit
import ReelCore
import ReelUI

/// The menu bar (design 9.11, mockup png/17). Key equivalents match design section 10; keys
/// without Command or Control are handled by the content view so they do not fire twice. There is
/// no Open Recent menu (the user keeps recent files off) and nothing is added to the recent
/// documents list. Checkmarks, titles that follow the state and enabling are set by
/// `AppDelegate.validateMenuItem`; the track lists are rebuilt by `TrackMenus` when a menu opens.
enum MainMenu {
    /// `offersUpdates` adds "Check for Updates..." under About; only the app's updater sets it.
    static func make(appName: String = "Reel", trackMenus: TrackMenus, offersUpdates: Bool = false) -> NSMenu {
        let main = build(appName: appName, trackMenus: trackMenus, offersUpdates: offersUpdates)
        NSApplication.shared.windowsMenu = main.item(withTitle: "Window")?.submenu
        return main
    }

    /// The menu bar without touching `NSApp`, so tests can read it.
    static func build(appName: String = "Reel", trackMenus: TrackMenus, offersUpdates: Bool = false) -> NSMenu {
        let main = NSMenu()
        let updates = offersUpdates ? [item("Check for Updates\u{2026}", #selector(AppDelegate.checkForUpdates(_:)))] : []
        main.addItem(submenu(appName, items: [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        ] + updates + [
            .separator(),
            item("Settings\u{2026}", #selector(AppDelegate.showSettings(_:)), key: ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), key: "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"),
        ]))
        main.addItem(submenu("File", items: [
            item("Open\u{2026}", #selector(AppDelegate.openDocument(_:)), key: "o"),
            .separator(),
            item("Close", #selector(AppDelegate.closeFile(_:)), key: "w"),
            item("Show in Finder", #selector(AppDelegate.showInFinder(_:))),
        ]))
        main.addItem(submenu("Playback", items: playbackItems(trackMenus: trackMenus)))
        main.addItem(submenu("Video", items: videoItems(trackMenus: trackMenus)))
        main.addItem(dynamicSubmenu("Audio", kind: .audio, trackMenus: trackMenus, items: audioItems() + [
            .separator(),
            dynamicSubmenu("Output Device", kind: .outputDevice, trackMenus: trackMenus, items: []),
        ]))
        main.addItem(dynamicSubmenu("Subtitles", kind: .subtitles, trackMenus: trackMenus, items: subtitleItems()))
        let window = submenu("Window", items: [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        main.addItem(window)
        return main
    }

    // MARK: Menus

    private static func playbackItems(trackMenus: TrackMenus) -> [NSMenuItem] {
        [
            item("Play/Pause", #selector(AppDelegate.togglePause(_:))),
            .separator(),
            item("Forward 5 Seconds", #selector(AppDelegate.seekForward(_:))),
            item("Back 5 Seconds", #selector(AppDelegate.seekBackward(_:))),
            item("Next Frame", #selector(AppDelegate.frameForward(_:))),
            item("Previous Frame", #selector(AppDelegate.frameBackward(_:))),
            .separator(),
            item("Next Episode", #selector(AppDelegate.nextEpisode(_:)), key: arrow(NSRightArrowFunctionKey)),
            item("Previous Episode", #selector(AppDelegate.previousEpisode(_:)), key: arrow(NSLeftArrowFunctionKey)),
            item("Auto-Advance to Next Episode", #selector(AppDelegate.toggleAutoAdvance(_:))),
            .separator(),
            dynamicSubmenu("Speed", kind: .speed, trackMenus: trackMenus, items: speedItems()),
            .separator(),
            item(LoopState.off.menuTitle, #selector(AppDelegate.abLoop(_:)), key: "l"),
            item("Loop File", #selector(AppDelegate.toggleFileLoop(_:)), key: "L"),
        ]
    }

    private static func videoItems(trackMenus: TrackMenus) -> [NSMenuItem] {
        [
            item("Half Size", #selector(AppDelegate.scaleHalf(_:)), key: "0"),
            item("Actual Size", #selector(AppDelegate.scaleActual(_:)), key: "1"),
            item("Double Size", #selector(AppDelegate.scaleDouble(_:)), key: "2"),
            item("Fit to Screen", #selector(AppDelegate.scaleFit(_:)), key: "3"),
            .separator(),
            item("Enter Full Screen", #selector(AppDelegate.toggleFullscreen(_:)), key: "f", modifiers: [.command, .control]),
            item("Enter Mini Player", #selector(AppDelegate.toggleMiniPlayer(_:)), key: "p", modifiers: [.command, .control]),
            .separator(),
            dynamicSubmenu("Video Track", kind: .video, trackMenus: trackMenus, items: []),
            item("Next Video Track", #selector(AppDelegate.cycleVideoTrack(_:)), key: "v", modifiers: [.command, .control]),
            .separator(),
            item("Take Screenshot", #selector(AppDelegate.takeScreenshot(_:)), key: "s"),
            item("Show Screenshots in Finder", #selector(AppDelegate.showScreenshots(_:))),
            .separator(),
            item("Video Info", #selector(AppDelegate.toggleVideoInfo(_:)), key: "i"),
        ]
    }

    /// The fixed part of the Audio menu; the tracks are inserted above it.
    static func audioItems() -> [NSMenuItem] {
        [
            item("Next Audio Track", #selector(AppDelegate.cycleAudioTrack(_:)), key: "a", modifiers: [.command, .control]),
            .separator(),
            item("Volume Up", #selector(AppDelegate.volumeUp(_:))),
            item("Volume Down", #selector(AppDelegate.volumeDown(_:))),
            item("Mute", #selector(AppDelegate.toggleMute(_:)), key: "/"),
            .separator(),
            item("Increase Audio Delay", #selector(AppDelegate.increaseAudioDelay(_:))),
            item("Decrease Audio Delay", #selector(AppDelegate.decreaseAudioDelay(_:))),
            item("Reset Audio Delay", #selector(AppDelegate.resetAudioDelay(_:))),
        ]
    }

    /// The fixed part of the Subtitles menu; Off and the tracks are inserted above it.
    static func subtitleItems() -> [NSMenuItem] {
        [
            item("Next Subtitle Track", #selector(AppDelegate.cycleSubtitleTrack(_:)), key: "s", modifiers: [.command, .control]),
            item("Add Subtitle File\u{2026}", #selector(AppDelegate.addSubtitleFile(_:)), key: "O"),
            .separator(),
            item("Show Subtitles", #selector(AppDelegate.toggleSubtitlesVisible(_:))),
            submenu("Delay", items: [
                item("Increase", #selector(AppDelegate.increaseSubtitleDelay(_:))),
                item("Decrease", #selector(AppDelegate.decreaseSubtitleDelay(_:))),
                item("Reset", #selector(AppDelegate.resetSubtitleDelay(_:))),
            ]),
            submenu("Size and Position", items: [
                item("Larger", #selector(AppDelegate.subtitleLarger(_:))),
                item("Smaller", #selector(AppDelegate.subtitleSmaller(_:))),
                item("Move Up", #selector(AppDelegate.subtitleUp(_:))),
                item("Move Down", #selector(AppDelegate.subtitleDown(_:))),
                item("Reset", #selector(AppDelegate.resetSubtitleStyle(_:))),
            ]),
        ]
    }

    /// The fixed part of the Speed submenu; the presets are inserted below it.
    static func speedItems() -> [NSMenuItem] {
        [
            item("Double", #selector(AppDelegate.doubleSpeed(_:)), key: "]"),
            item("Half", #selector(AppDelegate.halveSpeed(_:)), key: "["),
            item("Faster", #selector(AppDelegate.increaseSpeed(_:)), key: "]", modifiers: [.command, .option]),
            item("Slower", #selector(AppDelegate.decreaseSpeed(_:)), key: "[", modifiers: [.command, .option]),
            item("Normal", #selector(AppDelegate.resetSpeed(_:)), key: "\\"),
        ]
    }

    // MARK: Track items (also used by the context menu)

    /// Off, then every subtitle track with a checkmark on the selected one. Unsupported external
    /// files are disabled with the reason as a tooltip (design 9.11, D36).
    static func subtitleTrackItems(_ tracks: TrackState?) -> [NSMenuItem] {
        let off = item("Off", #selector(AppDelegate.selectSubtitleTrack(_:)))
        off.representedObject = SubtitleSelection.off
        off.state = (tracks?.selectedSubtitle ?? .off) == .off ? .on : .off
        var items = [off]
        for (index, track) in (tracks?.subtitles ?? []).enumerated() {
            let label = track.label(ordinal: index + 1)
            let entry = labelled(label, action: #selector(AppDelegate.selectSubtitleTrack(_:)))
            let selection = SubtitleSelection(track.id)
            entry.representedObject = selection
            entry.state = tracks?.selectedSubtitle == selection ? .on : .off
            if let reason = track.unsupportedReason {
                entry.toolTip = reason
                entry.action = nil
            }
            items.append(entry)
        }
        return items
    }

    static func audioTrackItems(_ tracks: TrackState?) -> [NSMenuItem] {
        guard let tracks, !tracks.audio.isEmpty else {
            return [disabled("No Audio Tracks")]
        }
        return tracks.audio.enumerated().map { index, track in
            let entry = labelled(track.label(ordinal: index + 1), action: #selector(AppDelegate.selectAudioTrack(_:)))
            entry.representedObject = track.streamIndex
            entry.state = tracks.selectedAudio == track.streamIndex ? .on : .off
            return entry
        }
    }

    static func videoTrackItems(_ tracks: TrackState?) -> [NSMenuItem] {
        guard let tracks, !tracks.video.isEmpty else {
            return [disabled("No Video Tracks")]
        }
        return tracks.video.map { track in
            let title = track.title.map { "\($0), " } ?? ""
            let entry = item("\(title)\(track.codec.uppercased()) \(track.width)x\(track.height)", #selector(AppDelegate.selectVideoTrack(_:)))
            entry.representedObject = track.streamIndex
            entry.state = tracks.selectedVideo == track.streamIndex ? .on : .off
            return entry
        }
    }

    /// System Default (with the default device's name), a separator, then the devices, the
    /// current choice checked (design 7.11). A chosen device that is unplugged stays, disabled.
    static func outputDeviceItems(_ entries: [OutputDeviceModel.Entry]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, entry) in entries.enumerated() {
            if index == 1 { items.append(.separator()) }
            let menuItem = item(entry.title, #selector(AppDelegate.selectOutputDevice(_:)))
            if let detail = entry.detail {
                let font = NSFont.menuFont(ofSize: 0)
                let title = NSMutableAttributedString(string: entry.title, attributes: [.font: font])
                title.append(NSAttributedString(string: " " + detail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                menuItem.attributedTitle = title
            }
            menuItem.representedObject = OutputDeviceMenuChoice(entry.choice)
            menuItem.state = entry.isSelected ? .on : .off
            if !entry.isConnected { menuItem.action = nil }
            items.append(menuItem)
        }
        return items
    }

    static func speedPresetItems(rate: Double) -> [NSMenuItem] {
        PlaybackSpeed.presets.map { preset in
            let entry = item(PlaybackSpeed.label(preset), #selector(AppDelegate.selectSpeedPreset(_:)))
            entry.representedObject = preset
            entry.state = abs(rate - preset) < 0.001 ? .on : .off
            return entry
        }
    }

    // MARK: Context menu (design 9.6)

    static func contextMenu(model: PlayerModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open\u{2026}", #selector(AppDelegate.openDocument(_:))))
        menu.addItem(item(model.isPlaying ? "Pause" : "Play", #selector(AppDelegate.togglePause(_:))))
        menu.addItem(item("Show in Finder", #selector(AppDelegate.showInFinder(_:))))
        guard model.hasMedia else { return menu }
        menu.addItem(.separator())
        let subtitles = subtitleTrackItems(model.tracks) + [.separator()] + subtitleItems()
        menu.addItem(submenu("Subtitles", items: subtitles))
        menu.addItem(submenu("Audio", items: audioTrackItems(model.tracks) + [.separator()] + audioItems()))
        menu.addItem(submenu("Speed", items: speedItems() + [.separator()] + speedPresetItems(rate: model.rate)))
        menu.addItem(.separator())
        menu.addItem(item("Take Screenshot", #selector(AppDelegate.takeScreenshot(_:))))
        menu.addItem(item("Enter Mini Player", #selector(AppDelegate.toggleMiniPlayer(_:))))
        return menu
    }

    /// Right click in the mini player (mini player design section 5).
    static func miniPlayerContextMenu(model: PlayerModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(model.isPlaying ? "Pause" : "Play", #selector(AppDelegate.togglePause(_:))))
        menu.addItem(item("Back to Window", #selector(AppDelegate.backToWindow(_:))))
        menu.addItem(item("Close Mini Player", #selector(AppDelegate.closeMiniPlayer(_:))))
        menu.addItem(.separator())
        let subtitles = subtitleTrackItems(model.tracks) + [.separator()] + subtitleItems()
        menu.addItem(submenu("Subtitles", items: subtitles))
        menu.addItem(submenu("Audio", items: audioTrackItems(model.tracks) + [.separator()] + audioItems()))
        menu.addItem(submenu("Speed", items: speedItems() + [.separator()] + speedPresetItems(rate: model.rate)))
        return menu
    }

    // MARK: Builders

    private static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func dynamicSubmenu(_ title: String, kind: TrackMenus.Kind, trackMenus: TrackMenus, items: [NSMenuItem]) -> NSMenuItem {
        let holder = submenu(title, items: items)
        if let menu = holder.submenu { trackMenus.manage(menu, kind: kind) }
        return holder
    }

    static func item(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// "Chinese (Simplified)" then "ASS, 简英双语" in the secondary colour, as in png/17.
    private static func labelled(_ label: TrackLabel, action: Selector) -> NSMenuItem {
        let entry = item(label.menuTitle, action)
        let detail = label.menuDetail
        guard !detail.isEmpty else { return entry }
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: label.menuTitle, attributes: [.font: font])
        title.append(NSAttributedString(
            string: " " + detail,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        entry.attributedTitle = title
        return entry
    }

    private static func arrow(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
    }
}

/// Rebuilds the track and speed lists when their menu opens, so they always show the open file's
/// tracks with the current choice checked. Items it adds carry `TrackMenus.dynamicTag`.
final class TrackMenus: NSObject, NSMenuDelegate {
    enum Kind {
        case audio, subtitles, video, speed, outputDevice
    }

    static let dynamicTag = 0x7265_656C
    weak var model: PlayerModel?
    weak var outputDevices: OutputDeviceModel?
    private var kinds: [ObjectIdentifier: Kind] = [:]

    func manage(_ menu: NSMenu, kind: Kind) {
        kinds[ObjectIdentifier(menu)] = kind
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kind = kinds[ObjectIdentifier(menu)] else { return }
        for item in menu.items where item.tag == TrackMenus.dynamicTag {
            menu.removeItem(item)
        }
        let tracks = model?.tracks
        var fresh: [NSMenuItem]
        var atEnd = false
        switch kind {
        case .audio: fresh = MainMenu.audioTrackItems(tracks)
        case .subtitles: fresh = MainMenu.subtitleTrackItems(tracks)
        case .video: fresh = MainMenu.videoTrackItems(tracks)
        case .speed:
            fresh = MainMenu.speedPresetItems(rate: model?.rate ?? PlaybackSpeed.normal)
            atEnd = true
        case .outputDevice:
            outputDevices?.refresh()
            fresh = MainMenu.outputDeviceItems(outputDevices?.entries ?? [])
        }
        if !menu.items.isEmpty {
            if atEnd { fresh.insert(.separator(), at: 0) } else { fresh.append(.separator()) }
        }
        fresh.forEach { $0.tag = TrackMenus.dynamicTag }
        let start = atEnd ? menu.items.count : 0
        for (offset, item) in fresh.enumerated() {
            menu.insertItem(item, at: start + offset)
        }
    }
}

/// The output device choice a menu item selects (its `representedObject`).
final class OutputDeviceMenuChoice: NSObject {
    let choice: OutputDeviceChoice

    init(_ choice: OutputDeviceChoice) {
        self.choice = choice
    }
}
