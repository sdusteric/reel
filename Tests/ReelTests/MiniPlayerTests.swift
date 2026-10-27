import AppKit
import Foundation
import ReelCore
import Testing
@testable import Reel
@testable import ReelUI

/// Sets the panel's frame at once instead of running the spring.
@MainActor
final class ImmediateSnapper: PanelSnapping {
    private(set) var snaps: [(frame: CGRect, velocity: CGVector)] = []
    func snap(_ window: NSWindow, to frame: CGRect, velocity: CGVector, completion: @escaping () -> Void) {
        snaps.append((frame, velocity))
        window.setFrame(frame, display: false)
        completion()
    }
    func stop() {}
}

/// Records panel moves and fades; each completes only when the test says so.
@MainActor
final class RecordingAnimator: PanelAnimating {
    struct Move: Equatable { var from: CGRect; var to: CGRect; var duration: TimeInterval }
    struct Fade: Equatable { var to: CGFloat; var duration: TimeInterval }
    private(set) var moves: [Move] = []
    private(set) var fades: [Fade] = []
    private var pending: [() -> Void] = []

    func move(_ window: NSWindow, to frame: CGRect, duration: TimeInterval, completion: @escaping () -> Void) {
        moves.append(Move(from: window.frame, to: frame, duration: duration))
        pending.append { window.setFrame(frame, display: false); completion() }
    }

    func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        fades.append(Fade(to: alpha, duration: duration))
        pending.append { window.alphaValue = alpha; completion() }
    }

    func finishAll() {
        let work = pending
        pending = []
        work.forEach { $0() }
    }
}

/// The mini player panel and the hand-off of the video surface (mini player design 3 and 4).
/// Panels are created but never shown: `show` only records.
@MainActor
@Suite(.serialized) struct MiniPlayerTests {
    static let screenA = ScreenInfo(id: "A", visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1414), isMain: true)
    static let screenB = ScreenInfo(id: "B", visibleFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1055), isMain: false)

    struct Rig {
        let model: PlayerModel
        let engines: EngineList
        let surface: VideoSurfaceView
        let home: SurfaceSlotView
        let store: StateStore
        let controller: MiniPlayerController
        let snapper: ImmediateSnapper
        let animator: RecordingAnimator
        var shown: () -> [NSPanel]
    }

    static func rig(
        scratch: AppScratch, screens: [ScreenInfo] = [screenA], placement: MiniPlayerPlacement? = nil, reduceMotion: Bool = false
    ) async throws -> Rig {
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        let surface = VideoSurfaceView(model: model)
        let home = SurfaceSlotView()
        home.host(surface)
        let store = StateStore(fileURL: scratch.url.appending(path: "state.json"))
        if let placement { try store.update { $0.miniPlayer = placement } }
        var shown: [NSPanel] = []
        let snapper = ImmediateSnapper()
        let animator = RecordingAnimator()
        let controller = MiniPlayerController(
            model: model, surface: surface, home: home, stateStore: store,
            screens: { screens }, show: { shown.append($0) }, snapper: snapper,
            animator: animator, reduceMotion: { reduceMotion }
        )
        return Rig(
            model: model, engines: engines, surface: surface, home: home, store: store,
            controller: controller, snapper: snapper, animator: animator, shown: { shown }
        )
    }

    @Test func panelNeverActivatesReel() {
        let panel = MiniPlayerPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 270))
        #expect(panel.styleMask.isSuperset(of: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isMovable, "Reel moves it, so a drag can snap")
        #expect(panel.title == "Mini Player")
        panel.isAppActive = { false }
        #expect(!panel.canBecomeKey)
        panel.isAppActive = { true }
        #expect(panel.canBecomeKey)
    }

    @Test func enterMovesTheSurfaceIntoThePanelAndLeaveMovesItBack() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        rig.controller.enter(from: CGRect(x: 320, y: 193, width: 1920, height: 1080), aspect: 16 / 9)
        rig.animator.finishAll()
        let panel = try #require(rig.controller.panel)
        #expect(rig.surface.window === panel)
        #expect(rig.surface.mode == .mini)
        #expect(rig.model.isMiniPlayerActive)
        #expect(rig.shown().count == 1)
        var done = false
        rig.controller.leave(to: CGRect(x: 320, y: 193, width: 1920, height: 1080)) { done = true }
        rig.animator.finishAll()
        await eventually("left") { done }
        #expect(rig.surface.superview === rig.home)
        #expect(rig.surface.mode == .window)
        #expect(rig.controller.panel == nil && !rig.controller.isActive)
        #expect(!rig.model.isMiniPlayerActive)
    }

    @Test func enterPlacesThePanelInTheSavedCorner() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let saved = MiniPlayerPlacement(corner: .topLeft, boxScale: 1, screen: "B")
        let rig = try await Self.rig(scratch: scratch, screens: [Self.screenA, Self.screenB], placement: saved)
        rig.controller.enter(from: .zero, aspect: 16 / 9)
        rig.animator.finishAll()
        let size = CGSize(width: 480, height: 270)
        #expect(rig.controller.panel?.frame == MiniPlayerGeometry.frame(size: size, corner: .topLeft, visible: Self.screenB.visibleFrame))

        let gone = try await Self.rig(scratch: scratch, screens: [Self.screenA], placement: MiniPlayerPlacement(corner: .topLeft, boxScale: 1, screen: "C"))
        gone.controller.enter(from: .zero, aspect: 16 / 9)
        gone.animator.finishAll()
        #expect(gone.controller.panel?.frame == MiniPlayerGeometry.frame(size: size, corner: .topLeft, visible: Self.screenA.visibleFrame))
    }

    @Test func dragReleaseSnapsAndSavesTheCorner() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        rig.controller.enter(from: .zero, aspect: 16 / 9)
        rig.animator.finishAll()
        let panel = try #require(rig.controller.panel)
        rig.controller.drag(.began)
        rig.controller.drag(.moved(CGVector(dx: -1500, dy: 900)))
        #expect(rig.store.state.miniPlayer.corner == .bottomRight, "nothing is saved during a drag")
        rig.controller.drag(.ended(velocity: .zero))
        #expect(rig.store.state.miniPlayer.corner == .topLeft)
        #expect(rig.store.state.miniPlayer.screen == "A")
        #expect(panel.frame == MiniPlayerGeometry.frame(size: CGSize(width: 480, height: 270), corner: .topLeft, visible: Self.screenA.visibleFrame))
        #expect(rig.snapper.snaps.count == 1)
    }

    @Test func resizeSavesTheBoxScale() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        rig.controller.enter(from: .zero, aspect: 16 / 9)
        rig.animator.finishAll()
        let panel = try #require(rig.controller.panel)
        panel.setFrame(CGRect(x: 1820, y: 20, width: 720, height: 405), display: false)
        #expect(rig.store.state.miniPlayer.boxScale == 1, "not during the resize")
        rig.controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        #expect(abs(rig.store.state.miniPlayer.boxScale - 1.5) < 0.0001)
    }

    @Test func subtitleFloorFollowsThePanel() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        let engine = try #require(rig.engines.all.first)
        rig.controller.enter(from: .zero, aspect: 16 / 9)
        await eventually("floor on") { engine.calls.contains(.subtitleMinimumHeight(208)) }
        rig.controller.leave(to: .zero) {}
        rig.animator.finishAll()
        await eventually("floor off") { engine.calls.contains(.subtitleMinimumHeight(nil)) }
    }

    @Test func pointerVelocityUsesTheLastTenthOfASecond() {
        var tracker = PointerVelocity()
        tracker.add(CGPoint(x: 0, y: 0), at: 0)
        tracker.add(CGPoint(x: 100, y: 0), at: 0.5)
        tracker.add(CGPoint(x: 110, y: -5), at: 0.55)
        tracker.add(CGPoint(x: 130, y: -15), at: 0.6)
        let velocity = tracker.velocity
        #expect(abs(velocity.dx - 300) < 0.001 && abs(velocity.dy + 150) < 0.001)
        tracker.add(CGPoint(x: 130, y: -15), at: 0.9)
        #expect(tracker.velocity == .zero, "a pause before release throws nothing")
    }

    @Test func pinchScalesAboutTheAnchoredCorner() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        rig.controller.enter(from: .zero, aspect: 16 / 9)
        rig.animator.finishAll()
        let panel = try #require(rig.controller.panel)
        let before = panel.frame
        rig.controller.magnify(by: 1.5)
        let size = MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 1.5, visible: Self.screenA.visibleFrame)
        #expect(panel.frame == MiniPlayerGeometry.frame(size: size, corner: .bottomRight, visible: Self.screenA.visibleFrame))
        #expect(panel.frame.maxX == before.maxX && panel.frame.minY == before.minY, "the bottom-right corner stays put")
        rig.controller.magnify(by: 0.01)
        #expect(panel.frame.size == CGSize(width: 256, height: 144), "clamped to the smallest box")
    }

    @Test func enterAnimatesFromTheWindowsVideoRect() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        let source = CGRect(x: 320, y: 193, width: 1920, height: 1080)
        rig.controller.enter(from: source, aspect: 16 / 9)
        let corner = MiniPlayerGeometry.frame(size: CGSize(width: 480, height: 270), corner: .bottomRight, visible: Self.screenA.visibleFrame)
        #expect(rig.animator.moves == [RecordingAnimator.Move(from: source, to: corner, duration: 0.3)])
        #expect(rig.animator.fades.isEmpty)
        #expect(rig.surface.window === rig.controller.panel, "the picture is in the panel from the first frame")

        let reduced = try await Self.rig(scratch: scratch, reduceMotion: true)
        reduced.controller.enter(from: source, aspect: 16 / 9)
        #expect(reduced.animator.moves.isEmpty, "no travel with Reduce Motion")
        #expect(reduced.controller.panel?.frame == corner)
        #expect(reduced.animator.fades == [RecordingAnimator.Fade(to: 1, duration: 0.15)])
    }

    @Test func leaveReturnsAlongTheSamePathAndSwapsBehindThePanel() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        let source = CGRect(x: 320, y: 193, width: 1920, height: 1080)
        rig.controller.enter(from: source, aspect: 16 / 9)
        rig.animator.finishAll()
        var order: [String] = []
        rig.controller.leave(to: source, beforeSwap: {
            order.append(rig.surface.superview === rig.home ? "home" : "panel")
        }) { order.append("done") }
        #expect(rig.animator.moves.last?.to == source && rig.animator.moves.last?.duration == 0.3)
        #expect(rig.surface.window === rig.controller.panel, "the picture travels in the panel")
        rig.animator.finishAll()
        #expect(order == ["panel", "done"], "the window is ordered in while the panel still covers it")
        #expect(rig.surface.superview === rig.home)
    }

    @Test func aSecondRequestRetargetsFromTheCurrentFrame() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        let source = CGRect(x: 320, y: 193, width: 1920, height: 1080)
        rig.controller.enter(from: source, aspect: 16 / 9)
        let panel = try #require(rig.controller.panel)
        let midway = CGRect(x: 1200, y: 100, width: 1200, height: 675)
        panel.setFrame(midway, display: false)
        var left = false
        rig.controller.leave(to: source) { left = true }
        #expect(rig.animator.moves.last?.from == midway)
        rig.animator.finishAll()
        #expect(left)
        #expect(rig.surface.superview === rig.home, "the enter's late completion does not pull the surface back")
        #expect(!rig.model.isMiniPlayerActive)
    }
}
