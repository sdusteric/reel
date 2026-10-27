# Reel Mini Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Apple Picture in Picture with Reel's own floating mini player: a non-activating panel that takes the window's video surface, snaps to a corner and moves in and out in one 0.3 s path.

**Architecture:** One `VideoSurfaceView` (display layer plus subtitle layer) moves between the main window's SwiftUI scene and a `MiniPlayerPanel`; the engine sees only a size change. Placement, sizing, corner choice and the snap spring are pure code in ReelUI, tested headless. Apple PiP, the crop workaround and the PiP subtitle compositor are deleted first.

**Tech Stack:** Swift 6, AppKit (`NSPanel`, `NSAnimationContext`, `NSView.displayLink`), SwiftUI overlay in `NSHostingView`, Swift Testing, swiftlint.

**Spec:** `docs/superpowers/specs/2026-10-26-reel-mini-player-design.md` (the "mini spec" below), and the main spec `docs/superpowers/specs/2026-10-24-reel-design.md`. Mockups: `docs/mockup/png/28-*.png` to `34-*.png`.

## Global Constraints

- Every rule in Reel's `CLAUDE.md`. In particular: build and test with your own `--scratch-path "$TMPDIR/reel-mini-<task>"` and delete it by exact path when done; `REEL_NO_UPDATES=1` for every test and shot; run the whole suite with `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8`.
- No test, shot or tool shows a window, orders a panel front, takes focus, makes a sound or touches the owner's media. Tests may create an `NSPanel` or `NSWindow` object but never call `orderFront`, `makeKeyAndOrderFront` or `orderFrontRegardless` on it; put those calls behind a closure the test replaces.
- Subagents never commit, push or install. The main session commits after each task's review and installs at the end with `scripts/bundle.sh --release --install` only when Reel is not running.
- No em dashes or en dashes in code, comments, strings or docs. American spelling in new copy. Comments only for the non-obvious, one or two lines.
- UI tasks (4 and 6): invoke the `impeccable`, `design-taste-frontend`, `unslop` and `find-animation-opportunities` skills, and check motion against `../app-updates/docs/motion-gate.md` and mini spec section 8.
- Exact values (points and seconds): default box 480 x 360, smallest box 256 x 192, largest box half the visible frame in each axis, inset 20, skip buttons hidden below 320 wide, subtitle floor height 208, enter and leave 0.3 s on `MotionCurve.easeOut` (`0.23, 1, 0.32, 1`), chrome fade-out before the move 0.1 s on `MotionCurve.easeIn`, Reduce Motion cross-fade 0.15 s each, snap spring bounce 0.15 and response 0.35 s, Reduce Motion snap 0.2 s ease-out, release projection deceleration rate 0.998.
- Copy, exactly: "Enter Mini Player", "Exit Mini Player", "Mini Player, ⌃⌘P" (tooltip), "Close Mini Player", "Back to Window", "Next episode in 3 s" (the number counts down), "Cancel", accessibility title "Mini Player".

## Review Focus

1. A portrait (9:16) or ultra-wide (2.39:1) video, or a next episode with a different aspect: the panel stays inside the box limits and keeps its corner. Tests in Task 1 and Task 7.
2. The panel's saved screen, or the screen it is on, is disconnected: it moves to the main screen's same corner without animation. Tests in Task 1 (`placement` with a missing screen) and Task 7 (`screenParametersChange`).
3. A new engine while the mini player is up (auto-advance, a file opened from Finder): `makeEngine` creates new layers inside the surface, which must stay in the panel. Test in Task 7.
4. Cmd+W, closing the window or quitting while the mini player is up: the panel closes, the surface goes home, and the window frame saved is the window's own, never the panel's. Test in Task 7.
5. Fullscreen requested while the mini player is up, or the mini player requested from fullscreen: one move at a time, never both. Tests in Task 7.

---

### Task 1: Geometry, placement state and the snap spring

**Files:**
- Create: `Sources/ReelUI/MiniPlayerGeometry.swift`
- Create: `Sources/ReelUI/SnapSpring.swift`
- Modify: `Sources/ReelCore/StateStore.swift` (new field on `RememberedState`)
- Test: `Tests/ReelUITests/MiniPlayerGeometryTests.swift`, `Tests/ReelUITests/SnapSpringTests.swift`, `Tests/ReelCoreTests/StateStoreTests.swift` (add to the existing suite, or create it if the round-trip tests live elsewhere; follow the existing `RememberedState` decode tests)

**Interfaces:**
- Produces (ReelCore): `public enum MiniPlayerCorner: String, Codable, Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }`; `public struct MiniPlayerPlacement: Codable, Sendable, Hashable { public var corner: MiniPlayerCorner = .bottomRight; public var boxScale: Double = 1; public var screen: String? }`; `RememberedState.miniPlayer: MiniPlayerPlacement` (default `MiniPlayerPlacement()`, decoded with the default when missing, like the other M2 fields).
- Produces (ReelUI, `nonisolated public enum MiniPlayerGeometry`, AppKit coordinates with y up):
  - `static let defaultBox = CGSize(width: 480, height: 360)`, `minimumBox = CGSize(width: 256, height: 192)`, `inset: CGFloat = 20`, `skipButtonsMinimumWidth: CGFloat = 320`, `subtitleFloorHeight: CGFloat = 208`, `decelerationRate: CGFloat = 0.998`
  - `static func size(aspect: CGFloat, boxScale: Double, visible: CGRect) -> CGSize`
  - `static func boxScale(for size: CGSize, aspect: CGFloat) -> Double` (the inverse of `size`, unclamped)
  - `static func frame(size: CGSize, corner: MiniPlayerCorner, visible: CGRect) -> CGRect`
  - `static func corner(releasing frame: CGRect, velocity: CGVector, visible: CGRect) -> MiniPlayerCorner` (velocity in points per second)
  - `static func screen(saved: String?, available: [String], fallback: String) -> String`
  - `static func showsSkipButtons(width: CGFloat) -> Bool`
- Produces (ReelUI): `nonisolated public struct SnapSpring { public init(bounce: Double = 0.15, response: Double = 0.35, reduceMotion: Bool); public func progress(at t: TimeInterval, initialVelocity: Double) -> Double; public func isSettled(at t: TimeInterval, initialVelocity: Double, distance: Double) -> Bool }` where progress runs 0 to 1 and `initialVelocity` is in units of distance per second divided by the distance. With `reduceMotion` it is the 0.2 s `MotionCurve.easeOut` curve and settles at 0.2 s.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct MiniPlayerGeometryTests {
    let visible = CGRect(x: 0, y: 0, width: 2560, height: 1414)

    @Test func defaultSizeFitsTheBoxForEachAspect() {
        #expect(MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 1, visible: visible) == CGSize(width: 480, height: 270))
        #expect(MiniPlayerGeometry.size(aspect: 4 / 3, boxScale: 1, visible: visible) == CGSize(width: 480, height: 360))
        let wide = MiniPlayerGeometry.size(aspect: 2.39, boxScale: 1, visible: visible)
        #expect(wide.width == 480 && abs(wide.height - 200.84) < 0.01)
        let tall = MiniPlayerGeometry.size(aspect: 9 / 16, boxScale: 1, visible: visible)
        #expect(abs(tall.width - 202.5) < 0.01 && tall.height == 360)
    }

    @Test func boxScaleIsClampedToTheSmallestAndLargestBox() {
        #expect(MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 0.1, visible: visible) == CGSize(width: 256, height: 144))
        let big = MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 10, visible: visible)
        #expect(abs(big.height - 707) < 0.01 && abs(big.width - 1256.89) < 0.01)
    }

    @Test func cornersSitTwentyPointsInsideTheVisibleFrame() {
        let size = CGSize(width: 480, height: 270)
        let shifted = CGRect(x: 0, y: 70, width: 2560, height: 1344) // a Dock at the bottom
        #expect(MiniPlayerGeometry.frame(size: size, corner: .bottomRight, visible: shifted).origin == CGPoint(x: 2060, y: 90))
        #expect(MiniPlayerGeometry.frame(size: size, corner: .topLeft, visible: shifted).origin == CGPoint(x: 20, y: 1124))
    }

    @Test func releaseVelocityProjectsTowardTheCornerItWasThrownAt() {
        let frame = CGRect(x: 1160, y: 565, width: 480, height: 270) // centre (1400, 700)
        #expect(MiniPlayerGeometry.corner(releasing: frame, velocity: CGVector(dx: 2000, dy: -1500), visible: visible) == .bottomRight)
        #expect(MiniPlayerGeometry.corner(releasing: frame, velocity: .zero, visible: visible) == .bottomRight)
        let upperLeft = CGRect(x: 960, y: 665, width: 480, height: 270) // centre (1200, 800)
        #expect(MiniPlayerGeometry.corner(releasing: upperLeft, velocity: .zero, visible: visible) == .topLeft)
    }

    @Test func aMissingScreenFallsBack() {
        #expect(MiniPlayerGeometry.screen(saved: "B", available: ["A", "B"], fallback: "A") == "B")
        #expect(MiniPlayerGeometry.screen(saved: "C", available: ["A", "B"], fallback: "A") == "A")
        #expect(MiniPlayerGeometry.screen(saved: nil, available: ["A"], fallback: "A") == "A")
    }

    @Test func skipButtonsNeedThreeHundredTwentyPoints() {
        #expect(MiniPlayerGeometry.showsSkipButtons(width: 320))
        #expect(!MiniPlayerGeometry.showsSkipButtons(width: 319.5))
    }

    @Test func boxScaleRoundTrips() {
        let size = MiniPlayerGeometry.size(aspect: 16 / 9, boxScale: 1.5, visible: visible)
        #expect(abs(MiniPlayerGeometry.boxScale(for: size, aspect: 16 / 9) - 1.5) < 0.0001)
    }
}

@Suite struct SnapSpringTests {
    @Test func startsAtZeroAndSettlesWithinSixHundredMilliseconds() {
        let spring = SnapSpring(reduceMotion: false)
        #expect(spring.progress(at: 0, initialVelocity: 0) == 0)
        #expect(abs(spring.progress(at: 0.6, initialVelocity: 0) - 1) < 0.005)
        #expect(spring.isSettled(at: 0.6, initialVelocity: 0, distance: 300))
    }

    @Test func overshootStaysUnderOnePercent() {
        let spring = SnapSpring(reduceMotion: false)
        let peak = stride(from: 0.0, through: 1.0, by: 0.005).map { spring.progress(at: $0, initialVelocity: 0) }.max() ?? 0
        #expect(peak < 1.01)
    }

    @Test func reduceMotionIsATwoHundredMillisecondEaseOutWithNoOvershoot() {
        let spring = SnapSpring(reduceMotion: true)
        #expect(spring.progress(at: 0.2, initialVelocity: 5) == 1)
        #expect(stride(from: 0.0, through: 0.3, by: 0.01).allSatisfy { spring.progress(at: $0, initialVelocity: 5) <= 1 })
    }
}
```

In the StateStore suite add `miniPlayerPlacementRoundTripsAndDefaults`: a `RememberedState` with `miniPlayer = MiniPlayerPlacement(corner: .topLeft, boxScale: 1.25, screen: "ABC")` encodes and decodes equal; a JSON document without the `miniPlayer` key decodes to `MiniPlayerPlacement()`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-1" --filter "MiniPlayerGeometryTests|SnapSpringTests|StateStore"`
Expected: FAIL, the types do not exist.

- [ ] **Step 3: Implement**

- `size`: fit `aspect` into `defaultBox * boxScale`, then clamp the box between `minimumBox` and `(visible.width / 2, visible.height / 2)` before fitting, so the result is always the aspect fitted into a clamped box.
- `corner`: project the frame's centre by `velocity * decelerationRate / (1 - decelerationRate) / 1000` (Apple's projection, velocity in points per second), then pick the quadrant of `visible` holding the projected point (`midX`, `midY`; y up, so above `midY` is top).
- `SnapSpring`: closed-form underdamped spring with mass 1, stiffness `(2 * .pi / response)^2`, damping ratio `1 - bounce`; settled when the remaining distance is under 0.5 pt and the speed under 10 pt/s.
- `RememberedState`: add the field, its `init` parameter (default `MiniPlayerPlacement()`) and the missing-key decode, following `outputDevice`.

- [ ] **Step 4: Run them to see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReelUI/MiniPlayerGeometry.swift Sources/ReelUI/SnapSpring.swift Sources/ReelCore/StateStore.swift Tests/ReelUITests/MiniPlayerGeometryTests.swift Tests/ReelUITests/SnapSpringTests.swift Tests/ReelCoreTests
git commit -m "Mini player geometry, placement state and snap spring"
```

---

### Task 2: Remove Apple Picture in Picture

Deletes the feature and renames the model's hooks to the mini player, so later tasks build on clean names. After this task the controller button, the menu item and Ctrl+Cmd+P call `model.toggleMiniPlayer()`, which does nothing yet.

**Files:**
- Delete: `Sources/Reel/PictureInPicture.swift`, `Sources/Reel/PiPSourceWindow.swift`, `Sources/ReelUI/PiPPlaceholder.swift`, `Sources/ReelEngine/PiPFrameCompositor.swift`, `Tests/ReelTests/PiPSourceWindowTests.swift`, `Tests/ReelEngineTests/PiPCompositeHDRTests.swift`
- Modify: `Sources/Reel/PlayerWindowController.swift` (drop `pictureInPicture`, `pipSource`, their wiring, the `!pipSource.isActive` guard in `saveFrame`, and `OcclusionGate.setPictureInPictureActive` with its flag), `Sources/Reel/AppDelegate.swift:150,176-193,311,421-422`, `Sources/Reel/MainMenu.swift:85,239`, `Sources/Reel/KeyHandling.swift:174`, `Sources/Reel/ShotMode.swift:11`
- Modify: `Sources/ReelUI/PlayerModel.swift:264-266,309,1490-1498`, `Sources/ReelUI/ControllerView.swift:127-147,368-375`, `Sources/ReelUI/PlayerSceneView.swift:62-66`, `Sources/ReelUI/Motion.swift:148-170`, `Sources/ReelUI/ShotRenderer.swift` (drop `case pip` and the placeholder snapshot)
- Modify: `Sources/ReelEngine/PlaybackEngine.swift` (drop `pipCompositor`, `pictureInPicture`, `setPictureInPictureActive`, `pictureInPictureCompositor`, the presenter's `pictureInPicture` setting and `pictureInPictureSubtitle()`, and the frame rewrite hook if nothing else uses it: `SeekExecutor.swift:272`), `Sources/ReelCore/PlayerEngine.swift:61` (comment), `Sources/ReelCore/InputMap.swift:51-52,348-349`
- Modify: `Sources/reelctl/HdrCommand.swift` and `Sources/reelctl/main.swift:20` (remove `--pip-check`), `scripts/accept.sh` (the `pipCheck` block, `--pip-check`, `PiPCompositeHDRTests` in both suite lists, `pip` in `M2_SCENARIOS`, `pipPlaceholderIsOpacityOnlyAndReducedWhenAsked`), `scripts/shots.sh` (drop `pip`, fix the count in the header comment), `CLAUDE.md` (`--pip-check`)
- Test: update `Tests/ReelTests/AppWiringTests.swift` (delete `PictureInPictureTests` and `pictureInPictureNeverCountsAsHidden`), `Tests/ReelUITests/PlayerModelTests.swift:566-579`, `Tests/ReelUITests/MotionTests.swift:67-74`, `Tests/ReelUITests/ControllerLayoutTests.swift`, `Tests/ReelEngineTests/PlaybackEngineTests.swift:614-673`, `Tests/ReelEngineTests/EnergyTests.swift:257-276`, `Tests/ReelCoreTests/InputMapTests.swift:236-246`

**Interfaces:**
- Produces (ReelCore): `InputAction.toggleMiniPlayer` replaces `.togglePictureInPicture`; IINA's `toggle-pip` command still maps to it, and Ctrl+Cmd+P stays its chord.
- Produces (ReelUI `PlayerModel`): `public internal(set) var isMiniPlayerActive = false`, `@ObservationIgnored public var onMiniPlayerRequest: ((Bool) -> Void)?`, `public func toggleMiniPlayer()` (does nothing without media; otherwise calls `onMiniPlayerRequest?(!isMiniPlayerActive)`), `public func setMiniPlayer(active: Bool)`.
- Produces (ReelUI `ControllerLayout.Buttons`): the field `pictureInPicture` is renamed `miniPlayer`; the drop order is unchanged.
- Produces (Reel `AppDelegate`): `@objc func toggleMiniPlayer(_:)`, menu title "Enter Mini Player" or "Exit Mini Player" from `model.isMiniPlayerActive`, disabled without media.

- [ ] **Step 1: Rewrite the tests that name PiP**

- `InputMapTests.screenshotLoopAndMiniPlayerKeys`: `action("Ctrl+Meta+p") == .toggleMiniPlayer` and `map.chord(for: .toggleMiniPlayer) == KeyChord(character: "p", modifiers: [.control, .command])`.
- `PlayerModelTests.miniPlayerRequestNeedsMedia`: with no media `toggleMiniPlayer()` sends nothing; with media it sends `[true]`, then after `setMiniPlayer(active: true)` it sends `false`.
- `ControllerLayoutTests`: the same cases with `miniPlayer` in place of `pictureInPicture`.
- `EnergyTests.occlusionHasNoEffectWhilePaused`: keep only the paused half.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-2" --filter "InputMapTests|PlayerModelTests|ControllerLayoutTests"`
Expected: FAIL on the missing names.

- [ ] **Step 3: Delete and rename** as listed under Files. The controller button keeps `pip.enter`, shows `pip.exit` in the accent color while `isMiniPlayerActive`, and its tooltip is "Mini Player, ⌃⌘P".

- [ ] **Step 4: Run the build, the whole suite and lint**

Run: `swift build --scratch-path "$TMPDIR/reel-mini-2" && SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8 REEL_NO_UPDATES=1 swift test --scratch-path "$TMPDIR/reel-mini-2" && swiftlint lint --strict && grep -rniE "pictureInPicture|PiPSource|PiPFrame|PiPPlaceholder|pip-check" Sources Tests scripts CLAUDE.md`
Expected: build and tests pass, lint clean, grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests scripts CLAUDE.md
git commit -m "Remove Apple Picture in Picture ahead of the mini player"
```

---

### Task 3: Engine: subtitle floor and the layer move

**Files:**
- Modify: `Sources/ReelCore/PlayerEngine.swift` (protocol), `Sources/ReelEngine/PlaybackEngine.swift` (subtitle presenter), `Tests/ReelUITests/FakeEngine.swift`
- Test: `Tests/ReelEngineTests/SubtitleRenderTests.swift`, create `Tests/ReelEngineTests/DisplayLayerMoveTests.swift`

**Interfaces:**
- Produces: `func setSubtitleMinimumHeight(_ points: Double?) async` on `PlayerEngine`. With a value, the presenter scales libass fonts by `max(1, points / layerHeightPoints)` (`ass_set_font_scale`), so a size 45 line keeps the size it has at that height. `nil` restores 1. `FakeEngine` records the calls.

- [ ] **Step 1: Write the failing tests**

- `SubtitleRenderTests.minimumHeightKeepsSmallLayersReadable`: render the SRT fixture used by the existing ink tests into a 256 x 144 pt layer at scale 2, once with no minimum and once with `setSubtitleMinimumHeight(208)`. The ink bounding box height with the minimum is `208 / 144` times the one without, within 10%.
- `DisplayLayerMoveTests.layerKeepsPresentingWhenMovedBetweenHosts` (the headless part of spike S1): play `hevc10_1080p24.mkv` with no audio renderer into a display layer added to a plain `CALayer` host A; every 2 s for 10 s remove it and add it to host B, then back. After each move: `status != .failed`, `requiresFlushToResumeDecoding == false`, and the engine's enqueued-frame counter keeps rising within 250 ms. Use the energy bench's headless setup (a standalone layer, `ClockedVideoSink` if the layer does not consume frames off screen, as 7.9 describes).

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-3" --filter "SubtitleRenderTests|DisplayLayerMoveTests"`
Expected: the subtitle test fails to compile; record whether the move test passes as written. If it fails on a flush, stop and report: Task 5 then adds the exact seek to the clock time after each move (mini spec section 3).

- [ ] **Step 3: Implement** `setSubtitleMinimumHeight` through the presenter's settings, like `setSubtitleAvoidance`, and re-render on change.

- [ ] **Step 4: Run them to see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReelCore/PlayerEngine.swift Sources/ReelEngine/PlaybackEngine.swift Tests/ReelUITests/FakeEngine.swift Tests/ReelEngineTests
git commit -m "Subtitle minimum height and a layer move check for the mini player"
```

---

### Task 4: The mini player overlay (SwiftUI)

UI task: run the four design skills and the motion gate (Global Constraints).

**Files:**
- Create: `Sources/ReelUI/MiniPlayerView.swift`
- Modify: `Sources/ReelUI/PlayerModel.swift` (a second `ChromeVisibility`), `Sources/ReelUI/ShotRenderer.swift` (mini scenarios), `scripts/shots.sh`
- Test: `Tests/ReelUITests/MiniPlayerViewTests.swift`, `Tests/ReelUITests/ShotRendererTests.swift`

**Interfaces:**
- Consumes: `MiniPlayerGeometry.showsSkipButtons(width:)`, the model hooks from Task 2.
- Produces: `public let miniChrome: ChromeVisibility` on `PlayerModel`, created like `chrome`, told `setPlaying` wherever `chrome` is, and pinned visible while `autoAdvance.isActive`; `public struct MiniPlayerView<Surface: View>: View` with `init(model: PlayerModel, actions: MiniPlayerActions, subtitle: ShotSubtitle? = nil, @ViewBuilder surface: () -> Surface)`; `public struct MiniPlayerActions { var close: () -> Void; var backToWindow: () -> Void }`; `nonisolated public enum MiniPlayerLayout` holding the mini spec section 5 values (`dim = 0.4`, `endDim = 0.6`, `cornerButton = 28`, `cornerGlyph = 15`, `cornerInset = 8`, `skipButton = 36`, `skipGlyph = 22`, `playButton = 48`, `playGlyph = 30`, `transportGap = 24`, `barSide = 12`, `barBottom = 10`, `track = 4`, `activeTrack = 6`, `thumb = 10`, `subtitleLift = 34`, `pauseMark = 24`, `pauseGlyph = 12`, `pauseMarkInset = 10`, `ring = 48`).
- Produces (shots): `ShotScenario` cases `miniHover = "mini-hover"`, `miniScrub = "mini-scrub"`, `miniPaused = "mini-paused"`, `miniSmall = "mini-small"`, `miniNext = "mini-next"`, rendered at the panel size (480 x 270, and 256 x 144 for `mini-small`) at scale 2.

- [ ] **Step 1: Write the failing tests**

- `MiniPlayerViewTests.chromeShowsOnlyWhileTheMiniChromeIsVisible`: render with `ShotRenderer`'s headless path at 480 x 270; with `miniChrome` hidden and playing, no control is in the accessibility tree; after `miniChrome.pointerMoved(to:)` the tree holds "Close Mini Player", "Back to Window", the skip buttons and play/pause.
- `MiniPlayerViewTests.pausedWithThePointerElsewhereShowsThePauseMark`: paused, chrome hidden: the "Paused" mark is present; playing: it is not.
- `MiniPlayerViewTests.narrowPanelDropsTheSkipButtons`: at 256 x 144 the skip buttons are absent and play/pause is present.
- `MiniPlayerViewTests.endOfEpisodePinsTheChrome`: with `autoAdvance.isActive`, the chrome is visible without pointer movement and shows "Next episode in 3 s" and "Cancel".
- `MiniPlayerViewTests.osdIsSmallerInTheMiniPlayer`: a volume OSD renders with 15 pt text 10 pt from the top-left corner.
- `ShotRendererTests`: each new scenario renders in light and dark at its size times 2 with non-zero ink in the control areas.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-4" --filter "MiniPlayerViewTests|ShotRendererTests"`
Expected: FAIL, the view does not exist.

- [ ] **Step 3: Implement `MiniPlayerView`** to match mockups `29` to `33` and mini spec section 5: a flat black dim (never material or blur), white glyphs at 94% with a 0 1 2 black 45% shadow, the seek bar from `SeekBar`'s logic at the mini sizes with the time label for scrubs and no thumbnail, the pause mark, the end-of-episode ring and row. The chrome fade uses `ChromeVisibility.animation`, and the pause mark appears in the same transaction as the fade-out. Hover backgrounds and the 0.94 press feedback reuse the controller's button style. While `miniChrome` is visible, the overlay reports `MiniPlayerLayout.subtitleLift` through the model's existing subtitle avoidance path. The OSD (9.5) shows in the mini player top left with a 10 pt inset and 15 pt text (`MiniPlayerLayout.osdInset = 10`, `osdText = 15`).

- [ ] **Step 4: Run them to see them pass, then render the shots**

Run: the Step 2 command, then `scripts/shots.sh mini-hover mini-scrub mini-paused mini-small mini-next`, and compare each PNG with its mockup in `docs/mockup/png/`.
Expected: PASS; the shots match the mockups' layout and values.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReelUI Tests/ReelUITests scripts/shots.sh
git commit -m "Mini player overlay and its shots"
```

---

### Task 5: The panel and the surface handoff

**Files:**
- Create: `Sources/Reel/MiniPlayerPanel.swift` (the panel and its content view), `Sources/Reel/MiniPlayerController.swift`
- Modify: `Sources/Reel/PlayerContentView.swift` (`VideoSurfaceView` modes), `Sources/ReelUI/PlayerSceneView.swift` (hide the surface while the mini player has it)
- Test: create `Tests/ReelTests/MiniPlayerTests.swift`

**Interfaces:**
- Consumes: `MiniPlayerGeometry`, `SnapSpring`, `MiniPlayerView`, `PlayerModel.miniChrome`, `setSubtitleMinimumHeight`.
- Produces: `final class MiniPlayerPanel: NSPanel` with the configuration of mini spec section 3 and `var isAppActive: () -> Bool = { NSApp.isActive }` read by `canBecomeKey`; `enum VideoSurfaceMode { case window, mini }` and `var mode: VideoSurfaceMode` on `VideoSurfaceView` (in `.mini`: no scroll handling, double click calls `onDoubleClick`, a drag past 3 pt moves the panel through `onPanelDrag: ((DragPhase) -> Void)?` with `enum DragPhase { case began, moved(CGVector), ended(velocity: CGVector) }`, a click on the picture keeps the 250 ms single-click pause); `final class MiniPlayerController` with `init(model: PlayerModel, surface: VideoSurfaceView, stateStore: StateStore, screens: @escaping () -> [ScreenInfo], show: @escaping (NSPanel) -> Void)`, `var isActive: Bool`, `func enter(from sourceRect: CGRect, aspect: CGFloat)`, `func leave(to targetRect: CGRect, completion: @escaping () -> Void)`, `var onLeaveRequest: ((LeaveKind) -> Void)?` with `enum LeaveKind { case backToWindow, close }`, and `struct ScreenInfo { let id: String; let visibleFrame: CGRect; let isMain: Bool }`.

- [ ] **Step 1: Write the failing tests** (fakes only; `show` is a closure that records the panel and never orders it front)

- `panelNeverActivatesReel`: the style mask contains `.nonactivatingPanel`, `.titled`, `.fullSizeContentView`, `.resizable`; `level == .floating`; the collection behavior contains `.canJoinAllSpaces` and `.fullScreenAuxiliary`; `hidesOnDeactivate == false`; `canBecomeKey` is false with `isAppActive = { false }` and true with `{ true }`.
- `enterMovesTheSurfaceIntoThePanelAndLeaveMovesItBack`: after `enter`, `surface.window === panel` and `surface.mode == .mini` and `model.isMiniPlayerActive`; after `leave` completes, the surface is back in the main window's scene, `mode == .window`, and the panel is closed.
- `enterPlacesThePanelInTheSavedCorner`: with `miniPlayer = MiniPlayerPlacement(corner: .topLeft, boxScale: 1, screen: "B")` and screens A (main) and B, the panel's final frame is `MiniPlayerGeometry.frame` on B's visible frame; with a missing screen "C" it lands on A.
- `dragReleaseSnapsAndSavesTheCorner`: `onPanelDrag(.began)`, `.moved(CGVector(dx: -1500, dy: 900))`, `.ended(velocity: .zero)` from the default bottom-right corner ends at `.topLeft`, written to `state.json` once, at the end.
- `resizeSavesTheBoxScale`: a live resize to 720 x 405 for 16:9 stores `boxScale == 1.5` when the resize ends, not during it.
- `subtitleFloorFollowsThePanel`: entering sends `setSubtitleMinimumHeight(208)` to the fake engine; leaving sends `nil`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-5" --filter MiniPlayerTests`
Expected: FAIL, the types do not exist.

- [ ] **Step 3: Implement**

- The panel's content view is a layer-backed view holding the surface under an `NSHostingView` of `MiniPlayerView`, with a tracking area `[.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]` that feeds `model.miniChrome`; it never hides the cursor.
- `PlayerSceneView` stops placing the surface while `model.isMiniPlayerActive` (a black area in its place); the panel's content view adds the same `VideoSurfaceView` instance. The surface is one object that changes parent; its layers move with it.
- Snap: on `.ended`, pick the corner with `MiniPlayerGeometry.corner`, then drive the panel origin with `SnapSpring` from an `NSView.displayLink(target:selector:)` on the panel's content view that runs only until `isSettled` and is invalidated then. A new `.began` stops it.
- Resize: the titled panel's own edge resizing with `contentAspectRatio` set to the video; a magnify gesture on the content view scales the panel about the corner it is anchored to, clamped by `MiniPlayerGeometry.size`. Both follow the hand with no animation.
- If Task 3's move test found a flush, follow each move with the engine's resync (the exact seek to the clock time used for occlusion).

- [ ] **Step 4: Run them to see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Reel Sources/ReelUI/PlayerSceneView.swift Tests/ReelTests/MiniPlayerTests.swift
git commit -m "Mini player panel and the video surface handoff"
```

---

### Task 6: The enter and leave move

UI task: run the four design skills and the motion gate.

**Files:**
- Modify: `Sources/Reel/MiniPlayerController.swift`, `Sources/ReelUI/Motion.swift`
- Test: `Tests/ReelUITests/MotionTests.swift`, `Tests/ReelTests/MiniPlayerTests.swift`

**Interfaces:**
- Produces (ReelUI `MotionTiming`): `static let miniPlayerMove: TimeInterval = 0.3`, `static let miniPlayerChromeOut: TimeInterval = 0.1`, `static let miniPlayerReducedFade: TimeInterval = 0.15`, and `static func miniPlayerMove(reduceMotion: Bool) -> (duration: TimeInterval, travels: Bool)`.

- [ ] **Step 1: Write the failing tests**

- `MotionTests.miniPlayerMoveUsesTheSharedEaseOut`: `miniPlayerMove(reduceMotion: false) == (0.3, true)`; `(reduceMotion: true) == (0.15, false)`; the timing function's control points equal `MotionCurve.easeOut`'s.
- `MiniPlayerTests.enterAnimatesFromTheWindowsVideoRect`: with an injected animator that records `(from, to, duration)`, entering from a 1920 x 1080 video rect at (320, 193) records that rect as `from`, the corner frame as `to` and 0.3; with Reduce Motion it records no travel (the panel is placed at `to`) and two 0.15 s fades.
- `MiniPlayerTests.aSecondRequestRetargetsFromTheCurrentFrame`: a leave requested halfway through an enter starts from the recorded current frame, not from the corner.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-6" --filter "MotionTests|MiniPlayerTests"`
Expected: FAIL on the missing tokens and animator.

- [ ] **Step 3: Implement** mini spec section 8 row 1: fade the window's title bar, traffic lights and controller over 0.1 s ease-in; place the panel at the window's video rect in screen coordinates, show it, hand it the surface, order the window out, and animate the panel frame to its corner in 0.3 s with `NSAnimationContext` and `MotionCurve.easeOut`'s timing function. Leaving reverses it into the window's video rect, then orders the window in, takes the surface back, closes the panel and fades the chrome in over 0.16 s. Put `NSAnimationContext` behind a small `PanelAnimating` protocol so tests inject the recorder. Dropped frames during the move can only be measured on screen, so that check is on the owner's list in Task 8.

- [ ] **Step 4: Run them to see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Reel/MiniPlayerController.swift Sources/ReelUI/Motion.swift Tests
git commit -m "Mini player enter and leave move"
```

---

### Task 7: App wiring

**Files:**
- Modify: `Sources/Reel/PlayerWindowController.swift`, `Sources/Reel/AppDelegate.swift`, `Sources/Reel/MainMenu.swift`, `Sources/Reel/KeyHandling.swift`, `Sources/Reel/DisplayRangeMonitor.swift`
- Test: `Tests/ReelTests/MiniPlayerTests.swift`, `Tests/ReelTests/AppWiringTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `PlayerWindowController.miniPlayer: MiniPlayerController`; `model.onMiniPlayerRequest` wired to enter or leave; `OcclusionGate` observing the panel while it is active (`func observe(window: NSWindow)`); `DisplayRangeMonitor.follow(window: NSWindow)`; `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)` returning to the window while the mini player is up.

- [ ] **Step 1: Write the failing tests**

- `requestWithoutMediaDoesNothing`: no panel is created.
- `enteringFromFullscreenLeavesFullscreenFirst`: with a fake fullscreen state, the request exits fullscreen and enters only after `windowDidExitFullScreen`.
- `fullscreenKeysLeaveTheMiniPlayerFirst`: Ctrl+Cmd+F while active leaves, then toggles fullscreen after the leave completes.
- `closeButtonPausesAndKeepsReelInactive`: `.close` pauses the model, leaves, and orders the window in through a recorded closure without activating the app.
- `backToWindowActivates`: `.backToWindow`, a double click and `applicationShouldHandleReopen` each leave and activate.
- `aNewEngineKeepsTheSurfaceInThePanel`: `makeEngine` while active leaves `surface.window === panel`, and the new layers are inside the surface.
- `closingTheWindowOrTheFileClosesThePanel`: `windowWillClose` and `closeFile()` while active close the panel, and the saved window frame equals the window's content rect from before entering.
- `aFailureCardLeavesTheMiniPlayer`: a `model.problem` while active leaves and orders the window in without activating.
- `occlusionFollowsThePanel`: while active, the panel's occlusion changes reach the gate and the hidden main window's do not.
- `screenParametersChangeMovesThePanel`: removing the panel's screen from the fake list moves it, with no animation, to the main screen's same corner.
- `aspectChangeKeepsTheCorner`: a new `MediaInfo` with 4:3 while active resizes the panel to the 4:3 box size anchored at its corner over `MotionTiming.windowResizeDuration`.
- `keysWorkWhileReelIsActive`: a Space key event sent to the panel's content view toggles play/pause.
- `contextMenuInTheMiniPlayer`: the menu holds Play/Pause, Back to Window, Close Mini Player, Subtitles, Audio, Speed.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --scratch-path "$TMPDIR/reel-mini-7" --filter "MiniPlayerTests|AppWiringTests"`
Expected: FAIL.

- [ ] **Step 3: Implement** mini spec sections 6 and 7. Scroll in the mini player stays ignored (Task 5). The panel's content view handles `keyDown` through `KeyHandling.handle` with this controller as the command target, so the section 10 keys work whenever Reel is active. Opening a file while active plays it in the panel. The panel's `NSAccessibility` title is "Mini Player".

- [ ] **Step 4: Run them to see them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Reel Tests/ReelTests
git commit -m "Wire the mini player into the window, menus, keys and system events"
```

---

### Task 8: Docs, full gate and install

**Files:**
- Modify: `docs/superpowers/specs/2026-10-24-reel-design.md` (the sections listed in mini spec section 3: 7.7, 7.9 including the display-link sentence, which becomes "no display link runs during playback; the mini player's snap runs one until it settles", 8.6, 9.1, 9.3, 9.6, 9.9 replaced by a summary that points at the mini spec, 9.11, 10, 12, 15.2, D37, D42, D52, D59, and a new decision for the mini player), `docs/superpowers/specs/2026-10-26-reel-mini-player-design.md` (status line: built, with the commit), `CLAUDE.md` if any command changed
- Delete: `docs/mockup/png/16-pip-dark.png`, `docs/mockup/png/16-pip-light.png`

- [ ] **Step 1: Update the docs** as listed. No dashes; American spelling in new text.

- [ ] **Step 2: Run the full gate once**

Run: `REEL_SCRATCH="$TMPDIR/reel-check" scripts/check.sh`
Expected: every gate passes, including `dashes`. Then `scripts/shots.sh` for all scenarios and look at every mini shot.

- [ ] **Step 3: Second motion-gate pass** on the built shots (`../app-updates/docs/motion-gate.md`), recorded in the mini spec under section 8.

- [ ] **Step 4: Commit and install** (main session only)

```bash
git add -A docs CLAUDE.md
git commit -m "Docs for the mini player; remove the PiP placeholder mockup"
scripts/bundle.sh --release --install   # only when Reel is not running
```

- [ ] **Step 5: Owner's hands-on check** (mini spec section 10, includes spike S2): enter and leave feel like one move with no lag; typing in the editor continues after clicking pause; drag and flick to each corner; resize and pinch; a Dock click returns the window; the mini player shows over a fullscreen app; Instruments shows no dropped frames during the enter move on the 5K display. If a click on the titled panel activates Reel, the follow-up switches to the borderless fallback of mini spec section 3.
