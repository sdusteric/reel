import AppKit

/// The menu bar. Key equivalents match design section 10; keys without Command are handled by
/// the content view so they do not fire twice. There is no Open Recent menu (the user keeps
/// recent files off) and nothing is added to the recent documents list.
enum MainMenu {
    static func make(appName: String = "Reel") -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appName, items: [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
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
        main.addItem(submenu("Playback", items: [
            item("Play/Pause", #selector(AppDelegate.togglePause(_:))),
            .separator(),
            item("Forward 5 Seconds", #selector(AppDelegate.seekForward(_:))),
            item("Back 5 Seconds", #selector(AppDelegate.seekBackward(_:))),
            item("Next Frame", #selector(AppDelegate.frameForward(_:))),
            item("Previous Frame", #selector(AppDelegate.frameBackward(_:))),
        ]))
        main.addItem(submenu("Audio", items: [
            item("Volume Up", #selector(AppDelegate.volumeUp(_:))),
            item("Volume Down", #selector(AppDelegate.volumeDown(_:))),
            item("Mute", #selector(AppDelegate.toggleMute(_:)), key: "/"),
        ]))
        main.addItem(submenu("Video", items: [
            item("Half Size", #selector(AppDelegate.scaleHalf(_:)), key: "0"),
            item("Actual Size", #selector(AppDelegate.scaleActual(_:)), key: "1"),
            item("Double Size", #selector(AppDelegate.scaleDouble(_:)), key: "2"),
            item("Fit to Screen", #selector(AppDelegate.scaleFit(_:)), key: "3"),
            .separator(),
            item("Enter Full Screen", #selector(AppDelegate.toggleFullscreen(_:)), key: "f", modifiers: [.command, .control]),
        ]))
        let window = submenu("Window", items: [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        main.addItem(window)
        NSApplication.shared.windowsMenu = window.submenu
        return main
    }

    private static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}
