import AppKit
import Observation
import SwiftUI

/// Whether a valid file drag is over the window (`isDropTargeted`). The app's drop views call the
/// matching method from each `NSDraggingDestination` callback.
@Observable
public final class DropTargetState {
    public private(set) var isDropTargeted = false

    public init() {}

    /// `draggingEntered` and `draggingUpdated`: targeted when the operation is a copy.
    public func dragged(operation: NSDragOperation) {
        let targeted = operation == .copy
        if targeted != isDropTargeted { isDropTargeted = targeted }
    }

    public func exited() { clear() }
    public func performed() { clear() }
    public func concluded() { clear() }

    private func clear() {
        if isDropTargeted { isDropTargeted = false }
    }
}

/// The tile's look while a file is dragged over it. Nothing changes while media is open: the
/// empty state is not on screen then, and nothing is drawn over a playing picture.
enum EmptyStateStyle {
    static let restFill = 0.1
    static let targetedFill = 0.16
    static let restRing = 0.14
    static let targetedRingOpacity = 0.6
    static let targetedScale: CGFloat = 1.04

    static func isHighlighted(targeted: Bool, hasMedia: Bool) -> Bool {
        targeted && !hasMedia
    }

    static func scale(highlighted: Bool, reduceMotion: Bool) -> CGFloat {
        highlighted && !reduceMotion ? targetedScale : 1
    }
}

/// The window with no file (design 9.1): black, with centred hints. The whole window is a drop
/// target (handled by the app's content view). The hints sit on the always-black video area, so
/// they use the dark appearance's secondary and tertiary colours; light ones would be invisible.
struct EmptyStateView: View {
    var dropTarget = DropTargetState()
    var hasMedia = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let highlighted = EmptyStateStyle.isHighlighted(targeted: dropTarget.isDropTargeted, hasMedia: hasMedia)
        ZStack {
            Color.black
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(highlighted ? EmptyStateStyle.targetedFill : EmptyStateStyle.restFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                highlighted ? Color.accentColor.opacity(EmptyStateStyle.targetedRingOpacity) : Color.white.opacity(EmptyStateStyle.restRing),
                                lineWidth: 0.5
                            )
                    )
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                    )
                    .frame(width: 60, height: 60)
                    .scaleEffect(EmptyStateStyle.scale(highlighted: highlighted, reduceMotion: reduceMotion))
                    .animation(Motion.dropTarget(targeted: highlighted, reduceMotion: reduceMotion), value: highlighted)
                    .padding(.bottom, 18)
                Text("Open a video")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .padding(.bottom, 6)
                HStack(spacing: 5) {
                    Text("Drop a file here or press")
                    Text("\u{2318}O")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.1)))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.58))
            }
            .padding(24)
            .environment(\.colorScheme, .dark)
        }
    }
}
