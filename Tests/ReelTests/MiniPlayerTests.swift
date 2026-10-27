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
        var shown: () -> [NSPanel]
    }

    static func rig(scratch: AppScratch, screens: [ScreenInfo] = [screenA], placement: MiniPlayerPlacement? = nil) async throws -> Rig {
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
        let controller = MiniPlayerController(
            model: model, surface: surface, home: home, stateStore: store,
            screens: { screens }, show: { shown.append($0) }, snapper: snapper
        )
        return Rig(model: model, engines: engines, surface: surface, home: home, store: store, controller: controller, snapper: snapper, shown: { shown })
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
        let panel = try #require(rig.controller.panel)
        #expect(rig.surface.window === panel)
        #expect(rig.surface.mode == .mini)
        #expect(rig.model.isMiniPlayerActive)
        #expect(rig.shown().count == 1)
        var done = false
        rig.controller.leave(to: CGRect(x: 320, y: 193, width: 1920, height: 1080)) { done = true }
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
        let size = CGSize(width: 480, height: 270)
        #expect(rig.controller.panel?.frame == MiniPlayerGeometry.frame(size: size, corner: .topLeft, visible: Self.screenB.visibleFrame))

        let gone = try await Self.rig(scratch: scratch, screens: [Self.screenA], placement: MiniPlayerPlacement(corner: .topLeft, boxScale: 1, screen: "C"))
        gone.controller.enter(from: .zero, aspect: 16 / 9)
        #expect(gone.controller.panel?.frame == MiniPlayerGeometry.frame(size: size, corner: .topLeft, visible: Self.screenA.visibleFrame))
    }

    @Test func dragReleaseSnapsAndSavesTheCorner() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let rig = try await Self.rig(scratch: scratch)
        rig.controller.enter(from: .zero, aspect: 16 / 9)
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
        let panel = try #require(rig.controller.panel)
        let before = panel.frame
        rig.controller.magnify(by: 1.5)
        let size = MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 1.5, visible: Self.screenA.visibleFrame)
        #expect(panel.frame == MiniPlayerGeometry.frame(size: size, corner: .bottomRight, visible: Self.screenA.visibleFrame))
        #expect(panel.frame.maxX == before.maxX && panel.frame.minY == before.minY, "the bottom-right corner stays put")
        rig.controller.magnify(by: 0.01)
        #expect(panel.frame.size == CGSize(width: 256, height: 144), "clamped to the smallest box")
    }
}
