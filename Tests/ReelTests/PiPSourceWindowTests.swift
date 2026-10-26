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
        let source = PiPSourceWindow(findPanel: { panel }, later: { $0() })

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
        let source = PiPSourceWindow(findPanel: { panel }, later: { $0() })
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
        let source = PiPSourceWindow(findPanel: { nil }, later: { $0() })
        source.begin(window: window)
        #expect(window.frame == original)
        #expect(window.alphaValue == 1)
        source.end()
        #expect(window.frame == original)
    }

    @Test func recognizesThePiPPanelByClassName() {
        #expect(PiPSourceWindow.isPiPPanel(className: "PIPPanel"))
        #expect(PiPSourceWindow.isPiPPanel(className: "PIPKit.PIPPanel"))
        #expect(!PiPSourceWindow.isPiPPanel(className: "NSPanel"))
    }
}
