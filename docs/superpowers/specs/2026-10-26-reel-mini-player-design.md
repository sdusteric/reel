# Reel mini player

Status: design, waiting for the owner's approval. Nothing is built. When built, it replaces section 9.9 (Picture in Picture) of `2026-10-24-reel-design.md` and removes the macOS crop workaround (`PiPSourceWindow`).

Mockups: `docs/mockup/index.html` frames 28 to 34, rendered to `docs/mockup/png/28-*.png` to `34-*.png` by `docs/mockup/render.sh`. All sizes are points.

## 1. Why

- Apple's Picture in Picture with a sample buffer display layer is broken on macOS 26.4 and later (FB22411168): it copies the source at 1:1 pixels, so a large window showed only a corner of the picture. The workaround in `PiPSourceWindow` shrinks the hidden window to the panel's size, which fixed the crop.
- What is left cannot be fixed from Reel. AVKit places its panel at the source window's size and position, then jumps it to its corner with no animation, so starting PiP lags and looks broken. The owner also saw a white border (fixed in 828123e, not yet confirmed on screen).
- How the owner uses it: the video sits in the bottom-right corner while they read or code with an AI tool in another app.

## 2. Goals, non-goals, anti-goals

Goals:

- The picture keeps playing in a small floating window in a corner while another app is in front.
- Clicking the mini player never takes keyboard focus from the app the owner is typing in.
- The same engine, clock, display layer, subtitles and HDR path as the main window: no second decode, no copied frames.
- Entering and leaving is one continuous move of the picture, 0.3 s.
- The size and corner are remembered.

Non-goals: a volume slider, track and speed panels, or the episode buttons inside the mini player (the context menu, the menu bar and the keys cover them); more than one mini player; keeping the main window visible while the mini player is up.

Anti-goals (a failure even if it works):

- Reel becoming the active app because the owner clicked pause.
- A second video pipeline or a frame compositor, like the one PiP needed for subtitles.
- Controls or a title drawn over the picture while the pointer is somewhere else.
- A scroll over the mini player changing the volume or seeking while the owner scrolls the document under it.

## 3. How it is built

- **`MiniPlayerPanel`**, an `NSPanel` in the `Reel` target. Style mask `[.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]`, title bar transparent with the title hidden and the three standard buttons hidden, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `isMovableByWindowBackground = false` (Reel handles the drag so it can snap). `canBecomeKey` is true only while Reel is the active app, so the keys work after Cmd+Tab, but a click while another app is in front does not activate Reel. A titled panel gets the system's edge resizing, corner radius and window shadow **(my call)**; spike S2 confirms that it still never activates on click, and if it does, the fallback is a borderless panel with its own 6 pt resize edges and a 14 pt corner mask.
- **One display layer.** Entering moves the video stack out of the main window's `PlayerContentView` (the `AVSampleBufferDisplayLayer` and the subtitle layer above it, kept together in one container view) into the panel's content view. Leaving moves it back. The engine gets only the new backing pixel size (for subtitle renders) and the panel as its occlusion source. Spike S1 confirms that the layer keeps presenting across the move with no flush; if it flushes, the move is followed by the exact seek to the clock time that the occlusion path already uses (7.9), so a picture is back within the scrub budget.
- **The main window** is ordered out when the move starts and ordered back in when it ends. Its frame is never changed and never saved while the mini player is up.
- **The SwiftUI overlay** for the mini player (`MiniPlayerView` in ReelUI) is a separate small view, not the controller in a smaller size: it has its own layout (section 5) and shares the model, the seek bar logic and the time formatting.
- **Removed:** `PictureInPicture.swift`, `PiPSourceWindow.swift` and their tests, `PiPPlaceholder`, `PiPFrameCompositor` and the subtitle compositing for PiP, `reelctl hdr --pip-check`, and the `AVKit` import if nothing else uses it.
- **Main spec sections to update in the same change:** 7.7 (the PiP bullet), 7.9 (occlusion), 8.6 (the PiP bullet), 9.1, 9.3 (the button), 9.6 (context menu), 9.9 (replaced by this document), 9.11 (Video menu), 10 (Ctrl+Cmd+P), 12 (package layout), 15.2 (the PiP placeholder rows and its motion row), decisions D37, D42, D52 and D59, and the `--pip-check` line in Reel's CLAUDE.md.

## 4. Size and place

- The panel fits a box and takes the video's display aspect inside it. Default box 480 x 360: a 16:9 video is 480 x 270, 4:3 is 480 x 360, 2.39:1 is 480 x 201, 9:16 is 203 x 360.
- Smallest box 256 x 192 (256 x 144 for 16:9). Largest box half the width and half the height of the screen's visible frame. `contentAspectRatio` is the video aspect, so resizing keeps it.
- It sits in a corner of the screen's visible frame, 20 pt in from both edges, so it stays above the Dock and below the menu bar. Default corner: bottom right.
- First use: the screen that holds the main window. Later: the saved screen if it is still connected, else the main screen, same corner.
- Saved in `state.json` as `miniPlayer: { corner, boxScale, screen }` (`boxScale` multiplies the default box, `screen` is the display's UUID). Written when a drag or resize ends, never during one.
- A new file with a different aspect (the next episode) keeps the corner and the box scale; the panel resizes toward its corner (motion row 4).

## 5. What it shows and does

Mockup frames: 28 on the desktop, 29 pointer over it, 30 scrubbing, 31 paused, 32 smallest size, 33 end of episode, 34 the enter move.

**Pointer elsewhere** (28, 31). Only the picture and the subtitles. While paused, a pause mark sits 10 pt from the bottom-left corner: a 24 pt circle of black 50% with a 0.5 pt white 16% ring and a 12 pt pause glyph at white 90%. A still frame could otherwise look stuck.

**Pointer over it** (29). A tracking area with `.activeAlways`, so it works while another app is in front. The chrome follows section 9.2: it shows on entry and on movement, hides 2.5 s after the last movement while playing and at once when the pointer leaves, and never hides while the pointer is over a control or a drag is in progress. The cursor never hides in the mini player.

- The picture dims under a flat black 40% layer. No material, no blur, no gradient. The colors are fixed in both appearances because everything sits on the picture.
- Top left: Close (`xmark`). Top right: Back to Window (`pip.exit`). 28 pt hit targets, 15 pt glyphs, 8 pt from the edges, hover circle white 18%.
- Center: back 10 s (36 pt target, 22 pt glyph), play/pause (48 pt target, 30 pt glyph), forward 10 s; 24 pt between targets. Glyphs white 94% with a shadow of 0 1 2 black 45%. Press feedback is the existing 0.94 scale (9.3).
- Bottom, 12 pt from the sides and 10 pt from the bottom: elapsed time, seek bar, remaining time. Times 11 pt medium, monospaced digits, white 88%. Bar 4 pt, white 30% unplayed, accent played; 6 pt with a 10 pt white thumb while hovered or dragged.
- Below 320 pt of panel width (32) the 10 s buttons drop out; the arrow keys and the media keys still skip.

**Clicks and gestures.**

- Single click on the picture: play/pause, delayed 250 ms for a double click (as in 9.6). Double click: back to the window.
- Click on the bar: exact seek. Drag on the bar (30) scrubs, with an 11 pt semibold time label on black 74% (radius 6) riding 6 pt above the bar over the pointer. There is no thumbnail. The picture is the preview.
- Drag anywhere else moves the panel; on release it snaps to a corner (motion row 2). Dragging it onto another display snaps to that display's corner.
- Resize from any edge or corner, aspect kept; a pinch scales it about the corner it is anchored to. Both follow the hand directly.
- Scroll over the panel does nothing.
- Right click: Play/Pause, Back to Window, Close Mini Player, then the Subtitles, Audio and Speed submenus from the menu bar.

**Keys.** When Reel is the active app (Cmd+Tab), the panel is key and the bindings of section 10 act on it, except the fullscreen keys, which leave the mini player and go fullscreen. Media keys and Now Playing work at all times through 9.10, which is how the owner pauses without leaving the editor.

**Subtitles.** Same layer, rendered at the panel's pixel size. They scale with the panel height, with a floor so a size 45 line is never under 13 pt (the scale of a 208 pt tall video). While the chrome shows, bottom lines lift above the bar by the rule of 8.5, using the bar's top edge, and snap as they do in the window.

**OSD.** The same messages as 9.5, top left with a 10 pt inset, text at 15 pt instead of 20.

**End of episode** (33). When auto-advance has a next file, the chrome stays up without hover: the picture dims to 60%, the 5 s countdown ring (48 pt) sits in the middle, and the bottom row shows the next episode's name (12 pt semibold) over "Next episode in 3 s" (11 pt medium, white 66%) with a Cancel capsule. A click on the ring plays it now; Cancel stays on the last frame with Replay in the middle. The next file plays in the mini player. No next file: the last frame stays with Replay.

## 6. Entering and leaving

Entering:

- From the controller button (`pip.enter`, tooltip "Mini Player, ⌃⌘P"), Video, Enter Mini Player (Ctrl+Cmd+P), or the context menu.
- From fullscreen, Reel leaves fullscreen first and then enters, so two moves never run at once **(my call)**.

Leaving:

- Back to Window, a double click, a click on Reel's Dock icon (`applicationShouldHandleReopen`), or Video, Exit Mini Player (Ctrl+Cmd+P while Reel is active). Reel activates and the window returns at its saved frame; playback carries on unchanged.
- Close pauses, returns the picture to the main window, and orders the window in behind the app in front without activating Reel **(my call)**. Nothing is lost, and Cmd+Tab finds it.
- Closing the file (Cmd+W while active) leaves the mini player and closes the file.
- Opening another file from Finder while the mini player is up plays it in the mini player **(my call)**.
- A failure card (9.14: the file can't be played, the drive was disconnected) leaves the mini player and shows in the window, ordered in without activating Reel.
- Quitting saves the state; the next launch opens in the window as usual.

## 7. System behavior

- Shows on every Space and over other apps' fullscreen Spaces.
- Energy (7.9): while the mini player is up, the occlusion gate watches the panel instead of the window. A panel fully covered for 1 s stops video decode as before. The display sleep assertion is unchanged.
- HDR (7.7): `DisplayRangeMonitor` follows the panel's screen. The layer keeps its EDR settings when it moves.
- Cmd+S screenshots, Now Playing, resume and auto-advance are unchanged.
- A disconnected display moves the panel to the main screen, same corner, no animation.
- Accessibility: the panel's title is "Mini Player"; every button has a label and a tooltip naming its action.

## 8. Motion

Checked against `app-updates/docs/motion-gate.md` and the find-animation-opportunities gate. Every row extends a token of section 15.1 or 15.2; there are no new curves.

| # | Moment | Today | Purpose | Frequency | Motion |
|---|---|---|---|---|---|
| 1 | Enter and leave (34) | AVKit jumps its panel with no animation and a lag | Spatial consistency: the picture goes where it went | Occasional (a few times a day) | The window's title bar and controller fade out over 0.1 s ease-in. The panel's frame moves from the window's video rect to its corner in 0.3 s on the shared ease-out (`0.23, 1, 0.32, 1`), no bounce, the layer resizing with it. Leaving runs the same path backwards, and the window's chrome fades in over 0.16 s at the end. A new request during the move retargets from the current frame. Reduce Motion: the window fades out and the panel fades in at its corner, 0.15 s each, no travel. |
| 2 | Release after dragging the panel | none (new) | Spatial consistency, with physics for a gesture | Occasional | Spring to the nearest corner, bounce 0.15, response 0.35 s, starting at the release velocity. The corner is chosen from the release point projected by the velocity (deceleration rate 0.998), so a flick toward a corner lands there. Grabbing it mid-flight stops the spring and the panel follows the pointer. Reduce Motion: 0.2 s ease-out, no overshoot. |
| 3 | Chrome over the picture | the window's chrome fade | State indication | Tens a day | The existing chrome tokens: 0.16 s ease-out in, 0.35 s ease-in out. The pause mark fades in the same transaction as the chrome fade-out, so it adds no motion of its own. Reduce Motion: 0.1 s opacity (as 9.2). |
| 4 | New video with a different aspect | the window's 0.2 s resize | Preventing a jarring change | Rare (auto-advance) | The existing window-resize token, 0.2 s, anchored at the panel's corner. Reduce Motion: no animation (as 15.2). |

Rejected:

- Subtitle lines lifting over the bar: the text is being read and the lift fires on every hover (function and frequency); they snap, as in 8.5.
- A scale or shadow lift on the panel when the pointer enters: no purpose beyond looks (purpose).
- A pulse on the countdown ring or an entrance for the end-of-episode row: the ring is a timer the owner reads, and the row appears with the chrome (function).
- Resize and pinch smoothing: direct manipulation follows the hand 1:1 (gesture rule).
- Play/pause glyph morph beyond the existing `.symbolEffect(.replace)`: already covered by 9.3.

Verdict: the mini player needs one authored move, the enter and leave path in row 1, and it is the highest-leverage item because it is the thing AVKit gets wrong today. Everything else reuses existing tokens or follows the hand.

## 9. Copy

| Where | Text |
|---|---|
| Video menu | Enter Mini Player, Exit Mini Player (⌃⌘P) |
| Controller button tooltip | Mini Player, ⌃⌘P |
| Top-left button, tooltip and label | Close Mini Player |
| Top-right button, tooltip and label | Back to Window |
| Context menu | Play, Pause, Back to Window, Close Mini Player, Subtitles, Audio, Speed |
| End of episode | the episode name (9.8), "Next episode in 3 s", Cancel |
| Accessibility title | Mini Player |

## 10. Tests and checks

All headless, with `REEL_HOME` in a temp dir, as Reel's CLAUDE.md requires.

- **`MiniPlayerGeometry`** (pure, ReelCore): fit in the box for 16:9, 4:3, 2.39:1 and 9:16; the minimum and maximum clamps; corner frames with the 20 pt inset on a visible frame that excludes a Dock and a menu bar; the nearest corner from a release point and a velocity; a saved screen that is gone; the `state.json` round trip.
- **Panel configuration**: the style mask contains `.nonactivatingPanel`, the level is `.floating`, the collection behavior has `.canJoinAllSpaces` and `.fullScreenAuxiliary`, and `canBecomeKey` follows the app's active state (a fake).
- **App wiring** (AppWiringTests style, fakes only): entering moves the video container into the panel and leaving moves it back; the fake engine receives only a size change; the main window frame is not saved while the mini player is up; Close pauses; the occlusion gate switches its source.
- **Shots**: `MiniPlayerView` through `ImageRenderer` in shot mode for frames 29 to 33, light and dark, compared with the mockups.
- **Spike S1 (before the build):** the display layer moved between two windows every 2 s during a 30 s HEVC 4K play, logging the layer's status, dropped frames and any flush. Decides whether section 3's fallback seek is needed.
- **Spike S2 (owner at the Mac):** a titled non-activating panel, clicked while a text editor is in front, keeps the editor's caret; the panel shows over another app's fullscreen Space.
- **Owner's hands-on check after the build:** enter and leave feel like one move with no lag; typing in the editor continues after clicking pause; drag and flick to each corner; resize and pinch; a Dock click returns the window; the mini player over a fullscreen app.
- The second motion-gate pass runs on the built shots before the polish commit.

## 11. My calls, for review

- A titled non-activating `NSPanel` for system resizing, corners and shadow (fallback: borderless with its own edges).
- Moving the one display layer between windows instead of a second layer or renderer.
- The main window is hidden while the mini player is up.
- Default box 480 x 360, smallest 256 x 192, largest half the visible frame, 20 pt inset, bottom right.
- Corner snapping on every release; no free placement.
- Close pauses and keeps the file open in the hidden-behind window.
- A file opened from Finder plays in the mini player.
- Fullscreen is left before entering.
- No scroll gestures on the panel.
- The 10 s buttons drop below 320 pt.
- Subtitle floor of 13 pt.

## 12. Left to the builder

- Where the video container view lives and how it is handed between the window and the panel, as long as the engine sees only a size change.
- The exact spring implementation (a `CADisplayLink` on the panel's frame or `NSAnimationContext` with a spring timing function), as long as it retargets on grab.
- Whether the enter move animates the panel frame directly or a temporary borderless window holding the layer; the target is no dropped frames on the 5K display, checked in Instruments.
