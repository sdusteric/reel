import AppKit
import Testing
@testable import Reel

// Stand-ins named like AVKit's private views, so the class-name match is exercised as it runs.
private final class AVPictureInPictureSampleBufferDisplayLayerHostView: NSView {}
private final class AVPictureInPictureCALayerHostView: NSView {}

/// The macOS PiP crop workaround (design 9.9). Windows here are made but never shown.
@Suite struct PiPSourceWindowTests {
    private func makeWindow(_ frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        window.setFrame(frame, display: false)
        return window
    }

    /// A PiP panel whose content holds the good host view with the blank overlay inside it.
    private func makePanel(size: CGSize) -> (NSWindow, overlay: NSView, host: NSView) {
        let panel = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let host = AVPictureInPictureSampleBufferDisplayLayerHostView(frame: CGRect(origin: .zero, size: size))
        let overlay = AVPictureInPictureCALayerHostView(frame: host.bounds)
        host.addSubview(overlay)
        panel.contentView?.addSubview(host)
        return (panel, overlay, host)
    }

    @Test func shrunkFrameKeepsTheTopLeftCorner() {
        let frame = PiPSourceWindow.shrunkFrame(current: CGRect(x: 100, y: 500, width: 1280, height: 720), contentSize: CGSize(width: 480, height: 270))
        #expect(frame == CGRect(x: 100, y: 950, width: 480, height: 270))
    }

    @Test func findsOnlyTheBlankOverlay() throws {
        let (panel, overlay, host) = makePanel(size: CGSize(width: 480, height: 270))
        let found = PiPSourceWindow.blankOverlays(in: try #require(panel.contentView))
        #expect(found.count == 1)
        #expect(found.first === overlay)
        #expect(!found.contains { $0 === host }, "the host view carries the scaled picture and must stay visible")
    }

    @Test func beginShrinksAndHidesTheWindowThenEndRestoresIt() throws {
        let original = CGRect(x: 100, y: 500, width: 1280, height: 720)
        let window = makeWindow(original)
        let (panel, overlay, host) = makePanel(size: CGSize(width: 480, height: 270))
        let source = PiPSourceWindow(findPanel: { panel }, later: { _, work in work() })

        source.begin(window: window)
        #expect(source.isActive)
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 480, height: 270))
        #expect(window.frame.maxY == original.maxY)
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(overlay.isHidden)
        #expect(!host.isHidden)

        source.end()
        #expect(!source.isActive)
        #expect(window.frame == original)
        #expect(window.alphaValue == 1)
        #expect(!window.ignoresMouseEvents)
        #expect(window.minSize == NSSize(width: 320, height: 200))
    }

    @Test func followsThePanelWhenItIsResized() throws {
        let window = makeWindow(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let (panel, _, _) = makePanel(size: CGSize(width: 480, height: 270))
        let source = PiPSourceWindow(findPanel: { panel }, later: { _, work in work() })
        source.begin(window: window)
        try #require(panel.contentView).setFrameSize(CGSize(width: 640, height: 360))
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 640, height: 360))
        source.end()
        try #require(panel.contentView).setFrameSize(CGSize(width: 800, height: 450))
        #expect(window.frame.size == CGSize(width: 1920, height: 1080), "no longer follows after PiP ends")
    }

    @Test func withoutAPanelTheWindowIsLeftAlone() {
        let original = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let window = makeWindow(original)
        let source = PiPSourceWindow(findPanel: { nil }, later: { _, work in work() })
        source.begin(window: window)
        #expect(window.frame == original)
        #expect(window.alphaValue == 1)
        source.end()
        #expect(window.frame == original)
    }

    @Test func followsThePanelWindowWhenItsContentIsResized() throws {
        let window = makeWindow(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let (panel, _, _) = makePanel(size: CGSize(width: 480, height: 270))
        let source = PiPSourceWindow(findPanel: { panel }, later: { _, work in work() })
        source.begin(window: window)
        panel.setContentSize(CGSize(width: 720, height: 405))
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 720, height: 405))
        source.end()
    }

    @Test func refitsAfterThePanelSettles() {
        // The panel can still be growing when PiP reports it started; later checks pick up its final size.
        let window = makeWindow(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let (panel, _, _) = makePanel(size: CGSize(width: 420, height: 236))
        var pending: [() -> Void] = []
        let source = PiPSourceWindow(findPanel: { panel }, later: { _, work in pending.append(work) })
        source.begin(window: window)
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 420, height: 236))
        panel.contentView?.postsFrameChangedNotifications = false
        panel.contentView?.setFrameSize(CGSize(width: 480, height: 270))
        pending.forEach { $0() }
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 480, height: 270))
        source.end()
    }

    @Test func logsSizesAndTheViewTree() throws {
        let window = makeWindow(CGRect(x: 0, y: 0, width: 1280, height: 720))
        let (panel, _, _) = makePanel(size: CGSize(width: 480, height: 270))
        var lines: [String] = []
        let source = PiPSourceWindow(findPanel: { panel }, later: { _, work in work() }, log: { lines.append($0) })
        source.begin(window: window)
        #expect(lines.contains { $0.hasPrefix("pip source: panel ") && $0.contains("480x270") })
        #expect(lines.contains { $0.contains("AVPictureInPictureCALayerHostView") && $0.contains("hidden") })
        source.end()
    }

    @Test func sizesTheVideoLayerNotTheWindowToThePanel() {
        // The video layer sits under the 32 pt title bar area, so it is 32 pt shorter than the
        // window; PiP copies only the layer, so the layer is what must match the panel.
        let window = makeWindow(CGRect(x: 0, y: 0, width: 1280, height: 720))
        let (panel, _, _) = makePanel(size: CGSize(width: 446, height: 251))
        let source = PiPSourceWindow(
            findPanel: { panel }, later: { _, work in work() },
            sourceSize: { [weak window] in
                guard let window else { return nil }
                let content = window.contentRect(forFrameRect: window.frame).size
                return CGSize(width: content.width, height: content.height - 32)
            }
        )
        source.begin(window: window)
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 446, height: 283))
        panel.setContentSize(CGSize(width: 501, height: 282))
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 501, height: 314))
        source.end()
        #expect(window.frame.size == CGSize(width: 1280, height: 720))
    }

    @Test func layerDumpShowsGeometryTransformsAndBackgrounds() {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 446, height: 251)
        root.backgroundColor = CGColor(gray: 1, alpha: 1)
        let child = CALayer()
        child.bounds = CGRect(x: 0, y: 0, width: 1599, height: 899)
        child.position = CGPoint(x: 223, y: 125)
        child.transform = CATransform3DMakeScale(0.25, 0.25, 1)
        root.addSublayer(child)
        let lines = PiPSourceWindow.describeLayers(root)
        #expect(lines.count == 2)
        #expect(lines[0].contains("background 1.00 1.00 1.00 1.00"))
        #expect(lines[1].contains("bounds 1599x899") && lines[1].contains("position (223, 125)") && lines[1].contains("transform 0.25 0.25 move 0 0"))
    }

    @Test func recognizesThePiPPanelByClassName() {
        #expect(PiPSourceWindow.isPiPPanel(className: "PIPPanel"))
        #expect(PiPSourceWindow.isPiPPanel(className: "PIPKit.PIPPanel"))
        #expect(!PiPSourceWindow.isPiPPanel(className: "NSPanel"))
    }
}
