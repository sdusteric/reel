import AppKit

/// Works around a macOS bug in Picture in Picture with an `AVSampleBufferDisplayLayer` source
/// (FB22411168, design 9.9): the PiP panel copies the source at 1:1 pixels instead of scaling it,
/// so a window larger than the panel shows only its bottom-left corner, and a blank black view is
/// drawn over the picture. While PiP runs, the player window is shrunk to the panel's content
/// size and made invisible, and the blank view is hidden. Both are undone when PiP stops.
///
/// The panel and the blank view are found by AVKit's private class names. If a macOS update
/// renames them, nothing is changed and PiP falls back to the cropped picture.
@MainActor
final class PiPSourceWindow {
    nonisolated static let panelClassName = "PIPPanel"
    nonisolated static let blankOverlayClassName = "AVPictureInPictureCALayerHostView"
    /// AVKit builds the panel's views after PiP starts.
    static let overlayDelay: TimeInterval = 0.1

    private struct Saved {
        var frame: CGRect
        var minSize: NSSize
        var alpha: CGFloat
        var ignoresMouseEvents: Bool
    }

    private let findPanel: @MainActor () -> NSWindow?
    private let later: @MainActor (@escaping @MainActor () -> Void) -> Void
    private weak var window: NSWindow?
    private weak var panel: NSWindow?
    private var saved: Saved?
    private var resizeObserver: (any NSObjectProtocol)?

    init(
        findPanel: @escaping @MainActor () -> NSWindow? = PiPSourceWindow.systemPanel,
        later: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = PiPSourceWindow.afterOverlayDelay
    ) {
        self.findPanel = findPanel
        self.later = later
    }

    var isActive: Bool { saved != nil }

    func begin(window: NSWindow) {
        guard saved == nil, let panel = findPanel(), let content = panel.contentView else { return }
        self.window = window
        self.panel = panel
        later { [weak self] in self?.hideBlankOverlays() }
        // A fullscreen window cannot be resized; only the blank view is hidden then.
        guard !window.styleMask.contains(.fullScreen) else { return }
        saved = Saved(frame: window.frame, minSize: window.minSize, alpha: window.alphaValue, ignoresMouseEvents: window.ignoresMouseEvents)
        window.minSize = NSSize(width: 1, height: 1)
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        fit(window, to: content.bounds.size)
        content.postsFrameChangedNotifications = true
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: content, queue: nil
        ) { [weak self] note in
            guard let size = (note.object as? NSView)?.bounds.size else { return }
            MainActor.assumeIsolated { self?.panelResized(to: size) }
        }
    }

    func end() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        defer {
            saved = nil
            panel = nil
        }
        guard let saved, let window else { return }
        window.setFrame(saved.frame, display: true)
        window.minSize = saved.minSize
        window.alphaValue = saved.alpha
        window.ignoresMouseEvents = saved.ignoresMouseEvents
    }

    private func panelResized(to size: CGSize) {
        guard saved != nil, let window else { return }
        fit(window, to: size)
        later { [weak self] in self?.hideBlankOverlays() }
    }

    private func fit(_ window: NSWindow, to contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let target = PiPSourceWindow.shrunkFrame(current: content, contentSize: contentSize)
        window.setFrame(window.frameRect(forContentRect: target), display: true)
    }

    private func hideBlankOverlays() {
        guard let root = panel?.contentView else { return }
        for view in PiPSourceWindow.blankOverlays(in: root) { view.isHidden = true }
    }

    /// The content rect for `contentSize` that keeps the top-left corner where it was.
    nonisolated static func shrunkFrame(current: CGRect, contentSize: CGSize) -> CGRect {
        CGRect(x: current.minX, y: current.maxY - contentSize.height, width: contentSize.width, height: contentSize.height)
    }

    /// The blank views (exact class name) anywhere under `root`; never their host view.
    static func blankOverlays(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)) == blankOverlayClassName { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    nonisolated static func isPiPPanel(className: String) -> Bool {
        className == panelClassName || className.hasSuffix(".\(panelClassName)")
    }

    static func systemPanel() -> NSWindow? {
        NSApplication.shared.windows.first { isPiPPanel(className: String(describing: type(of: $0))) }
    }

    static func afterOverlayDelay(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayDelay) { MainActor.assumeIsolated { work() } }
    }
}
