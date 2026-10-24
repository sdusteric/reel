import ReelCore
import SwiftUI

/// Everything inside the player window: the video surface, the title, the controller and the
/// OSD (design 9 and 15). The app passes the display layer host as `surface`; shot mode passes a
/// SwiftUI `Image` of a decoded frame, so the screenshots show the same view the window hosts.
public struct PlayerSceneView<Surface: View>: View {
    public static var titleBarHeight: CGFloat { 28 }

    let model: PlayerModel
    let actions: SceneActions
    let surface: Surface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOrigin: CGRect?

    public init(model: PlayerModel, actions: SceneActions = SceneActions(), @ViewBuilder surface: () -> Surface) {
        self.model = model
        self.actions = actions
        self.surface = surface()
    }

    private var showsEmptyState: Bool {
        !model.hasMedia && model.playbackState != .opening
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Color.black
                surface
                    .frame(width: size.width, height: size.height)
                if showsEmptyState {
                    EmptyStateView(errorMessage: model.errorMessage)
                        .frame(width: size.width, height: size.height)
                }
                if !showsEmptyState {
                    chrome(in: size)
                }
                OSDView(model: model)
                    .padding(.leading, OSDView.edgeInset)
                    .padding(.top, OSDView.edgeInset + (model.chrome.isVisible ? PlayerSceneView.titleBarHeight : 0))
                    .animation(.easeOut(duration: 0.12), value: model.chrome.isVisible)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func chrome(in size: CGSize) -> some View {
        let visible = model.chrome.isVisible
        let frame = ControllerLayout.frame(in: size, centerX: model.controllerCenterX, bottomY: model.controllerBottomY)
        ZStack(alignment: .topLeading) {
            TitleBar(title: model.title ?? "")
                .frame(width: size.width, height: PlayerSceneView.titleBarHeight)
            ControllerView(model: model, actions: actions)
                .frame(width: frame.width, height: frame.height)
                .contentShape(RoundedRectangle(cornerRadius: ControllerLayout.cornerRadius, style: .continuous))
                .gesture(controllerDrag(frame: frame, size: size))
                .onTapGesture(count: 2) { model.resetControllerPosition() }
                .position(x: frame.midX, y: frame.midY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(ChromeVisibility.animation(visible: visible, reduceMotion: reduceMotion), value: visible)
    }

    /// The controller follows the pointer with no animation, clamped 16 pt from the edges.
    private func controllerDrag(frame: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
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
                    model.moveController(centerX: fractions.centerX, bottomY: fractions.bottomY)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                model.chrome.setDragging(false)
            }
    }
}

/// The title, centred in the title bar area over a thin material band, fading with the chrome.
struct TitleBar: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 80)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChromeStyle.stroke(colorScheme)).frame(height: 0.5)
        }
    }
}
