import ReelCore
import SwiftUI

/// Everything inside the player window: the video surface, the subtitle layer, the title, the
/// controller with its panels and the OSD (design 9 and 15). The app passes the display layer
/// host as `surface`; shot mode passes a SwiftUI `Image` of a decoded frame, so the screenshots
/// show the same view the window hosts.
public struct PlayerSceneView<Surface: View>: View {
    public static var titleBarHeight: CGFloat { 28 }

    let model: PlayerModel
    let actions: SceneActions
    let surface: Surface
    let subtitle: ShotSubtitle?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOrigin: CGRect?

    /// `subtitle` is for screenshots only: in the app the engine's layer draws the subtitles.
    public init(
        model: PlayerModel,
        actions: SceneActions = SceneActions(),
        subtitle: ShotSubtitle? = nil,
        @ViewBuilder surface: () -> Surface
    ) {
        self.model = model
        self.actions = actions
        self.subtitle = subtitle
        self.surface = surface()
    }

    private var showsEmptyState: Bool {
        !model.hasMedia && model.playbackState != .opening
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = ControllerLayout.frame(
                in: size,
                centerX: model.controllerCenterX,
                bottomY: model.controllerBottomY,
                fullscreen: model.isFullscreen
            )
            ZStack(alignment: .topLeading) {
                Color.black
                surface
                    .frame(width: size.width, height: size.height)
                SubtitleOverlay(model: model, windowSize: size, controllerFrame: showsEmptyState ? nil : frame, shot: subtitle)
                    .frame(width: size.width, height: size.height)
                if model.isPictureInPictureActive {
                    PiPPlaceholder(snapshot: model.pictureInPictureSnapshot) { model.togglePictureInPicture() }
                        .frame(width: size.width, height: size.height)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(Motion.easeOut(0.2)),
                            removal: .opacity.animation(Motion.easeIn(0.15))
                        ))
                }
                if showsEmptyState {
                    // Clicks fall through to the video surface, which moves the window on drag.
                    EmptyStateView(errorMessage: model.errorMessage)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
                if model.activePanel != nil {
                    // A click anywhere else closes the panel and does nothing more.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.closePanel() }
                        .frame(width: size.width, height: size.height)
                }
                if !showsEmptyState {
                    chrome(in: size, frame: frame)
                }
                OSDView(model: model)
                    .padding(.leading, OSDView.edgeInset)
                    .padding(.top, OSDView.edgeInset + (model.chrome.isVisible ? 28 : 0))
                    .animation(.easeOut(duration: 0.12), value: model.chrome.isVisible)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func chrome(in size: CGSize, frame: CGRect) -> some View {
        let visible = model.chrome.isVisible
        ZStack(alignment: .topLeading) {
            TitleBar(title: model.title ?? "", endsAt: model.isFullscreen ? model.endsAtLabel : nil)
                .frame(width: size.width, height: PlayerSceneView.titleBarHeight)
            ControllerView(
                model: model,
                actions: actions,
                context: ControllerContext(windowSize: size, frame: frame),
                onDragChanged: { controllerDragChanged($0, frame: frame, size: size) },
                onDragEnded: controllerDragEnded,
                onReset: { model.resetControllerPosition() }
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(ChromeVisibility.animation(visible: visible, reduceMotion: reduceMotion), value: visible)
    }

    /// The controller follows the pointer with no animation, clamped 16 pt from the edges. In
    /// fullscreen only the horizontal position moves: the bottom edge is fixed.
    private func controllerDragChanged(_ value: DragGesture.Value, frame: CGRect, size: CGSize) {
        let origin = dragOrigin ?? frame
        if dragOrigin == nil {
            dragOrigin = origin
            model.chrome.setDragging(true)
        }
        let moved = origin.offsetBy(dx: value.translation.width, dy: value.translation.height)
        let wanted = ControllerLayout.fractions(for: moved, in: size)
        let clamped = ControllerLayout.frame(in: size, centerX: wanted.centerX, bottomY: wanted.bottomY)
        let fractions = ControllerLayout.fractions(for: clamped, in: size)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.moveController(
                centerX: fractions.centerX,
                bottomY: model.isFullscreen ? model.controllerBottomY : fractions.bottomY
            )
        }
    }

    private func controllerDragEnded() {
        dragOrigin = nil
        model.chrome.setDragging(false)
    }
}

/// The title, centred in the title bar area over a soft scrim that fades into the picture. The
/// text is white in both appearances: it always sits on video.
struct TitleBar: View {
    static let height: CGFloat = 28
    let title: String
    /// "Ends at 22:47", fullscreen only (design 9.1, D41).
    var endsAt: String?

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .black.opacity(0.3), location: 0.3),
                    .init(color: .black.opacity(0.12), location: 0.65),
                    .init(color: .black.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: TitleBar.height + 40)
            .frame(height: TitleBar.height, alignment: .top)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 80)
            if let endsAt {
                Text(endsAt)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.72))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }
}
