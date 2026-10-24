import Foundation
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct SeekBarTests {
    private let width: CGFloat = 400

    private func openModel(_ scratch: UIScratch, engine: FakeEngine) async throws -> PlayerModel {
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        return model
    }

    @Test func dragSendsScrubsThenOneExact() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let model = try await openModel(scratch, engine: engine)
        let interaction = SeekBarInteraction(model: model)

        interaction.dragChanged(startX: 100, x: 100, width: width)
        interaction.dragChanged(startX: 100, x: 101, width: width)
        #expect(!interaction.isDragging, "under 2 pt is still a click")
        interaction.dragChanged(startX: 100, x: 120, width: width)
        #expect(model.isScrubbing)
        #expect(model.position == .seconds(180), "the thumb moves before the engine answers")
        interaction.dragChanged(startX: 100, x: 160, width: width)
        interaction.dragChanged(startX: 100, x: 200, width: width)
        interaction.dragEnded(x: 200, width: width)
        #expect(!model.isScrubbing)
        await model.waitForEngineCommands()
        #expect(engine.seeks == [
            .scrub(.seconds(180)), .scrub(.seconds(240)), .scrub(.seconds(300)), .exact(.seconds(300)),
        ])
    }

    @Test func clickWithoutDragIsOneExactSeek() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let model = try await openModel(scratch, engine: engine)
        let interaction = SeekBarInteraction(model: model)
        interaction.dragChanged(startX: 300, x: 300, width: width)
        interaction.dragEnded(x: 301, width: width)
        await model.waitForEngineCommands()
        #expect(engine.seeks.count == 1)
        #expect(engine.seeks.first?.isExact == true)
        #expect(engine.seeks.first?.target == .seconds(451.5))
    }

    @Test func dragsPastTheEndsClamp() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let engine = FakeEngine()
        let model = try await openModel(scratch, engine: engine)
        let interaction = SeekBarInteraction(model: model)
        interaction.dragChanged(startX: 10, x: -50, width: width)
        interaction.dragChanged(startX: 10, x: 900, width: width)
        interaction.dragEnded(x: 900, width: width)
        await model.waitForEngineCommands()
        #expect(engine.seeks == [.scrub(.zero), .scrub(.seconds(600)), .exact(.seconds(600))])
    }

    @Test func clockUpdatesDoNotMoveTheThumbDuringADrag() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let model = try await openModel(scratch, engine: FakeEngine())
        let interaction = SeekBarInteraction(model: model)
        interaction.dragChanged(startX: 0, x: 200, width: width)
        model.handle(.time(.seconds(3)))
        #expect(model.position == .seconds(300))
        interaction.dragEnded(x: 200, width: width)
    }

    @Test func hoverPillShowsTheTimeUnderThePointer() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let model = try await openModel(scratch, engine: FakeEngine())
        model.setSeekHover(0.25)
        #expect(TimeFormat.hover(model.time(atFraction: model.seekHoverFraction ?? 0), duration: model.duration) == "02:30")
        model.setSeekHover(1.7)
        #expect(model.seekHoverFraction == 1)
        model.setSeekHover(nil)
        #expect(model.seekHoverFraction == nil)
    }
}
