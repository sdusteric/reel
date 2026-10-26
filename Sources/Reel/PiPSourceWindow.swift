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
    /// The panel can still be animating to its size when PiP reports it started, without telling
    /// its content view; the window is refitted once it has settled.
    static let settleChecks: [TimeInterval] = [0.3, 1.0]

    private struct Saved {
        var frame: CGRect
        var minSize: NSSize
        var alpha: CGFloat
        var ignoresMouseEvents: Bool
    }

    private let findPanel: @MainActor () -> NSWindow?
    private let later: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let log: @MainActor (String) -> Void
    /// The video layer's size in window points. PiP copies only that layer, and it sits under the
    /// title bar area, so the window is sized to make the layer (not the window) match the panel.
    var sourceSize: @MainActor () -> CGSize?
    /// Window content minus the video layer, measured when PiP starts.
    private var chrome = CGSize.zero
    private weak var window: NSWindow?
    private weak var panel: NSWindow?
    private var saved: Saved?
    private var observers: [any NSObjectProtocol] = []

    init(
        findPanel: @escaping @MainActor () -> NSWindow? = PiPSourceWindow.systemPanel,
        later: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = PiPSourceWindow.after,
        log: @escaping @MainActor (String) -> Void = { _ in },
        sourceSize: @escaping @MainActor () -> CGSize? = { nil }
    ) {
        self.findPanel = findPanel
        self.later = later
        self.log = log
        self.sourceSize = sourceSize
    }

    var isActive: Bool { saved != nil }

    func begin(window: NSWindow) {
        guard saved == nil, let panel = findPanel(), let content = panel.contentView else {
            log("pip source: no panel found, window left as it is")
            return
        }
        self.window = window
        self.panel = panel
        log("pip source: panel \(Self.sizeText(content.bounds.size)) at \(panel.backingScaleFactor)x, frame \(Self.rectText(panel.frame)); window \(Self.sizeText(window.contentRect(forFrameRect: window.frame).size)) at \(window.backingScaleFactor)x")
        logTree("at start")
        later(0.05) { [weak self] in self?.logTree("at 0.05 s") }
        later(Self.overlayDelay) { [weak self] in
            self?.hideBlankOverlays()
            self?.logTree("at 0.1 s, blank view hidden")
        }
        // A fullscreen window cannot be resized; only the blank view is hidden then.
        guard !window.styleMask.contains(.fullScreen) else {
            log("pip source: fullscreen, window not resized")
            return
        }
        let windowContent = window.contentRect(forFrameRect: window.frame).size
        if let layer = sourceSize() {
            chrome = CGSize(width: max(0, windowContent.width - layer.width), height: max(0, windowContent.height - layer.height))
        }
        saved = Saved(frame: window.frame, minSize: window.minSize, alpha: window.alphaValue, ignoresMouseEvents: window.ignoresMouseEvents)
        window.minSize = NSSize(width: 1, height: 1)
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        fit(window, to: content.bounds.size)
        content.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelResized() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelResized() }
            },
        ]
        for delay in Self.settleChecks {
            later(delay) { [weak self] in
                self?.panelResized()
                self?.logTree("at \(delay) s")
            }
        }
    }

    func end() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        defer {
            saved = nil
            panel = nil
            chrome = .zero
        }
        guard let saved, let window else { return }
        window.setFrame(saved.frame, display: true)
        window.minSize = saved.minSize
        window.alphaValue = saved.alpha
        window.ignoresMouseEvents = saved.ignoresMouseEvents
    }

    private func panelResized() {
        guard saved != nil, let window, let size = panel?.contentView?.bounds.size else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard current != CGSize(width: size.width + chrome.width, height: size.height + chrome.height) else { return }
        fit(window, to: size)
        log("pip source: panel now \(Self.sizeText(size)), window \(Self.sizeText(window.contentRect(forFrameRect: window.frame).size))")
        later(0.3) { [weak self] in self?.logTree("0.3 s after a resize") }
        later(Self.overlayDelay) { [weak self] in self?.hideBlankOverlays() }
    }

    private func fit(_ window: NSWindow, to contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let wanted = CGSize(width: contentSize.width + chrome.width, height: contentSize.height + chrome.height)
        let target = PiPSourceWindow.shrunkFrame(current: content, contentSize: wanted)
        window.setFrame(window.frameRect(forContentRect: target), display: true)
    }

    private func logTree(_ moment: String) {
        guard let panel, let root = panel.contentView else { return }
        var text = "pip source: panel tree \(moment), panel frame \(Self.rectText(panel.frame))\n" + Self.describe(root).joined(separator: "\n")
        if let layer = root.layer { text += "\nlayers:\n" + Self.describeLayers(layer).joined(separator: "\n") }
        log(text)
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

    static func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    /// One line per view and per layer under `root`: class, frame, and what can hide, scale or
    /// tint the picture. For the log only.
    static func describe(_ root: NSView, maxDepth: Int = 8) -> [String] {
        var lines: [String] = []
        func layerLine(_ layer: CALayer, depth: Int) {
            guard depth <= maxDepth else { return }
            let pad = String(repeating: "  ", count: depth)
            var line = "\(pad)layer \(type(of: layer)) \(rectText(layer.frame)) scale \(layer.contentsScale)"
            if layer.transform.m11 != 1 || layer.transform.m22 != 1 { line += " transform \(layer.transform.m11)x\(layer.transform.m22)" }
            if let color = layer.backgroundColor, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) {
                line += String(format: " background %.2f %.2f %.2f %.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
            }
            if layer.isHidden { line += " hidden" }
            if layer.contents != nil { line += " contents" }
            lines.append(line)
            layer.sublayers?.forEach { layerLine($0, depth: depth + 1) }
        }
        func viewLine(_ view: NSView, depth: Int) {
            guard depth <= maxDepth else { return }
            let pad = String(repeating: "  ", count: depth)
            lines.append("\(pad)\(type(of: view)) \(rectText(view.frame))\(view.isHidden ? " hidden" : "")")
            if let layer = view.layer, view.subviews.isEmpty { layer.sublayers?.forEach { layerLine($0, depth: depth + 1) } }
            view.subviews.forEach { viewLine($0, depth: depth + 1) }
        }
        viewLine(root, depth: 0)
        return lines
    }

    /// Every layer under `root` with the geometry that decides where the picture lands. Log only.
    static func describeLayers(_ root: CALayer, maxDepth: Int = 12) -> [String] {
        var lines: [String] = []
        func line(_ layer: CALayer, depth: Int) {
            guard depth <= maxDepth else { return }
            let t = layer.transform
            var text = String(repeating: "  ", count: depth) + "\(type(of: layer))"
            text += " bounds \(sizeText(layer.bounds.size)) position (\(Int(layer.position.x)), \(Int(layer.position.y)))"
            text += String(format: " anchor %.2f %.2f", layer.anchorPoint.x, layer.anchorPoint.y)
            if !CATransform3DIsIdentity(t) { text += String(format: " transform %.2f %.2f move %.0f %.0f", t.m11, t.m22, t.m41, t.m42) }
            if !CATransform3DIsIdentity(layer.sublayerTransform) {
                let s = layer.sublayerTransform
                text += String(format: " sublayerTransform %.2f %.2f move %.0f %.0f", s.m11, s.m22, s.m41, s.m42)
            }
            text += " scale \(layer.contentsScale)"
            if let color = layer.backgroundColor, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) {
                text += String(format: " background %.2f %.2f %.2f %.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
            }
            if layer.opacity < 1 { text += " opacity \(layer.opacity)" }
            if layer.masksToBounds { text += " masks" }
            if layer.isHidden { text += " hidden" }
            if layer.contents != nil { text += " contents \(layer.contentsGravity.rawValue)" }
            if layer.delegate is NSView { text += " (view)" }
            lines.append(text)
            layer.sublayers?.forEach { line($0, depth: depth + 1) }
        }
        line(root, depth: 0)
        return lines
    }

    nonisolated static func sizeText(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }
    nonisolated static func rectText(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))x\(Int(rect.height)))"
    }
}
