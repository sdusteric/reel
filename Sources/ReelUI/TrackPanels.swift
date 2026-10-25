import AppKit
import ReelCore
import SwiftUI

/// The panels that open above the controller (design 9.7). One at a time.
nonisolated public enum ControllerPanel: Hashable, Sendable {
    case subtitles, audio, speed
}

/// Keys a panel handles while it is open: Up and Down move, Return chooses, Esc closes. The app's
/// key handler forwards them, since the content view holds first responder.
nonisolated public enum PanelKey: Sendable {
    case up, down, confirm, escape
}

enum PanelMetrics {
    static let trackWidth: CGFloat = 320
    static let speedWidth: CGFloat = 264
    static let padding: CGFloat = 6
    static let cornerRadius: CGFloat = 16
    static let rowRadius: CGFloat = 10
    static let rowHeight: CGFloat = 30
    static let twoLineRowHeight: CGFloat = 42
    static let checkColumn: CGFloat = 22
    /// Row insets (mockup `.prow`: 5 10 5 6) and the gap after the check column, so labels sit
    /// 40 pt in from the panel edge, under the header's 16 pt inset plus the check column.
    static let rowLeading: CGFloat = 6
    static let rowTrailing: CGFloat = 10
    static let rowVertical: CGFloat = 5
    static let checkGap: CGFloat = 6
    /// Where row labels start inside the panel padding.
    static var labelInset: CGFloat { rowLeading + checkColumn + checkGap }
    static let separatorMargin: CGFloat = 5
    static let stepperFill = 0.08
    static let stepperDivider = 0.15
    static let stepperGlyph = 0.8
    static let actionIconSize: CGFloat = 14
    static let actionIconOpacity = 0.6
    /// More tracks than this and the list scrolls.
    static let scrollThreshold = 9
    static let maximumHeightFraction: CGFloat = 0.6
    /// Header, separators and the footer rows, subtracted from the 60% budget for the list.
    static let fixedHeight: CGFloat = 190

    static func width(for panel: ControllerPanel) -> CGFloat {
        panel == .speed ? speedWidth : trackWidth
    }

    /// The scrolling list's height: its rows, or what is left of 60% of the window.
    static func listHeight(rows: [TrackRow], windowHeight: CGFloat) -> CGFloat {
        let content = rows.reduce(CGFloat(0)) { $0 + ($1.detail == nil ? rowHeight : twoLineRowHeight) }
        let budget = max(120, windowHeight * maximumHeightFraction - fixedHeight)
        return min(content, budget)
    }
}

/// One row of the subtitle or audio panel and of the matching menu.
struct TrackRow: Identifiable, Equatable {
    enum Choice: Equatable {
        case subtitle(SubtitleSelection)
        case audio(Int)
    }

    var id: String
    var title: String
    var detail: String?
    var tag: String?
    var isSelected: Bool
    var isEnabled = true
    var choice: Choice

    var height: CGFloat { detail == nil ? PanelMetrics.rowHeight : PanelMetrics.twoLineRowHeight }
}

/// Labels and selection for the panels, from the engine's `TrackState`.
enum TrackPanelContent {
    /// Off first, then the embedded tracks in container order, then external files.
    static func subtitleRows(_ tracks: TrackState?) -> [TrackRow] {
        guard let tracks, !tracks.subtitles.isEmpty else { return [] }
        var rows = [TrackRow(
            id: "subtitle-off",
            title: "Off",
            isSelected: tracks.selectedSubtitle == .off,
            choice: .subtitle(.off)
        )]
        for (offset, track) in tracks.subtitles.enumerated() {
            let label = track.label(ordinal: offset + 1)
            let selection = SubtitleSelection(track.id)
            rows.append(TrackRow(
                id: "subtitle-\(track.id)",
                title: label.title,
                detail: label.detail,
                tag: label.tag,
                isSelected: tracks.selectedSubtitle == selection,
                isEnabled: track.isSupported,
                choice: .subtitle(selection)
            ))
        }
        return rows
    }

    static func audioRows(_ tracks: TrackState?) -> [TrackRow] {
        guard let tracks else { return [] }
        return tracks.audio.enumerated().map { offset, track in
            let label = track.label(ordinal: offset + 1)
            return TrackRow(
                id: "audio-\(track.streamIndex)",
                title: label.title,
                detail: label.detail,
                tag: label.tag,
                isSelected: tracks.selectedAudio == track.streamIndex,
                choice: .audio(track.streamIndex)
            )
        }
    }

    /// "7 tracks", "1 track".
    static func countText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "track" : "tracks")"
    }

    /// The first line of a track's label for the OSD and VoiceOver: "Chinese (Simplified), ASS".
    static func shortName(_ label: TrackLabel) -> String {
        "\(label.title), \(label.tag)"
    }
}

/// Chooses the view for the open panel.
struct PanelHost: View {
    let model: PlayerModel
    let panel: ControllerPanel
    let windowHeight: CGFloat

    var body: some View {
        switch panel {
        case .subtitles, .audio:
            TrackPanelView(model: model, panel: panel, windowHeight: windowHeight)
        case .speed:
            SpeedPanelView(model: model)
        }
    }
}

/// The subtitle and audio panels: a header with the track count, the rows, steppers and, for
/// subtitles, Add Subtitle File (design 9.7, mockups png/02, 03 and 18).
struct TrackPanelView: View {
    let model: PlayerModel
    let panel: ControllerPanel
    let windowHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var isSubtitles: Bool { panel == .subtitles }
    private var rows: [TrackRow] { model.panelRows }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                title: isSubtitles ? "Subtitles" : "Audio",
                count: trackCount > 0 ? TrackPanelContent.countText(trackCount) : nil
            )
            if rows.isEmpty {
                Text(isSubtitles ? "No subtitles in this file or next to it." : "No audio tracks in this file.")
                    .font(.system(size: 12))
                    .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
                    .padding(.leading, PanelMetrics.labelInset)
                    .padding(.trailing, PanelMetrics.rowTrailing)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            } else {
                list
            }
            if isSubtitles {
                if !rows.isEmpty {
                    PanelSeparator()
                    PanelStepperRow(
                        label: "Delay",
                        value: SubtitleStyle.delayText(model.subtitleDelay),
                        minus: { model.stepSubtitleDelay(by: -$0) },
                        plus: { model.stepSubtitleDelay(by: $0) }
                    )
                    PanelStepperRow(
                        label: "Size",
                        value: model.subtitleStyle.sizeLabel,
                        minus: { _ in model.stepSubtitleSize(by: -1) },
                        plus: { _ in model.stepSubtitleSize(by: 1) }
                    )
                }
                PanelSeparator()
                PanelActionRow(symbol: "doc.badge.plus", title: "Add Subtitle File...") {
                    model.addSubtitleFile()
                }
            } else if !rows.isEmpty {
                PanelSeparator()
                PanelStepperRow(
                    label: "Delay",
                    value: SubtitleStyle.delayText(model.audioDelay),
                    minus: { model.stepAudioDelay(by: -$0) },
                    plus: { model.stepAudioDelay(by: $0) }
                )
            }
        }
        .padding(PanelMetrics.padding)
        .frame(width: PanelMetrics.trackWidth)
        .continuousSurface(radius: PanelMetrics.cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSubtitles ? "Subtitles" : "Audio")
    }

    private var trackCount: Int {
        isSubtitles ? model.tracks?.subtitles.count ?? 0 : model.tracks?.audio.count ?? 0
    }

    @ViewBuilder
    private var list: some View {
        if rows.count > PanelMetrics.scrollThreshold {
            ScrollViewReader { proxy in
                ScrollView {
                    rowStack
                }
                .frame(height: PanelMetrics.listHeight(rows: rows, windowHeight: windowHeight))
                .onAppear {
                    if let selected = rows.first(where: \.isSelected) {
                        proxy.scrollTo(selected.id, anchor: .center)
                    }
                }
            }
        } else {
            rowStack
        }
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                TrackRowView(row: row, isHighlighted: model.panelHighlight == index) {
                    model.choose(row)
                }
                .id(row.id)
            }
        }
    }
}

struct PanelHeader: View {
    let title: String
    var count: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.9))
            Spacer(minLength: 8)
            if let count {
                Text(count)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct PanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, PanelMetrics.separatorMargin)
    }
}

/// One track row: check column, label, optional second line and a right-aligned format tag.
struct TrackRowView: View {
    let row: TrackRow
    let isHighlighted: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ZStack {
                    if row.isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                }
                .frame(width: PanelMetrics.checkColumn)
                .padding(.trailing, PanelMetrics.checkGap)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let tag = row.tag {
                    FormatTag(text: tag)
                }
            }
            .padding(.leading, PanelMetrics.rowLeading)
            .padding(.trailing, PanelMetrics.rowTrailing)
            .padding(.vertical, PanelMetrics.rowVertical)
            .frame(maxWidth: .infinity, minHeight: row.height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .opacity((hovering || isHighlighted) && row.isEnabled ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous))
            .opacity(row.isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .onHover { hovering = $0 }
        .help(row.isEnabled ? "" : (row.detail ?? "Not supported"))
        .accessibilityLabel(row.title)
        .accessibilityValue(row.isSelected ? "Selected" : "")
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    }
}

/// A format tag: 10.5 pt semibold, +3% tracking, a 0.5 pt ring at 24%, radius 5.
struct FormatTag: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(ChromeStyle.tagText(colorScheme))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.24), lineWidth: 0.5)
            )
    }
}

/// A label, a value and a minus and plus stepper (60 x 26, two 30 pt cells). Alt-click steps by
/// 0.5 s for delays.
struct PanelStepperRow: View {
    let label: String
    let value: String
    var altScale: Double = 5
    /// Called with the step multiplier: 1, or `altScale` with Option held.
    let minus: (Double) -> Void
    let plus: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
                .padding(.leading, PanelMetrics.checkColumn + PanelMetrics.checkGap)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.trailing, 8)
            PanelStepper(
                decrement: { minus(NSEvent.modifierFlags.contains(.option) ? altScale : 1) },
                increment: { plus(NSEvent.modifierFlags.contains(.option) ? altScale : 1) }
            )
        }
        .padding(.leading, PanelMetrics.rowLeading)
        .padding(.trailing, PanelMetrics.rowTrailing)
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct PanelStepper: View {
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StepperCell(symbol: "minus", label: "Decrease", action: decrement)
            Rectangle().fill(Color.primary.opacity(PanelMetrics.stepperDivider)).frame(width: 0.5, height: 26)
            StepperCell(symbol: "plus", label: "Increase", action: increment)
        }
        .frame(width: 60, height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(PanelMetrics.stepperFill)))
    }
}

private struct StepperCell: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(PanelMetrics.stepperGlyph))
                .frame(width: 29.75, height: 26)
                .background(Color.primary.opacity(hovering ? 0.08 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// A full-width row with an icon, like Add Subtitle File.
struct PanelActionRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: PanelMetrics.actionIconSize, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(PanelMetrics.actionIconOpacity))
                    .frame(width: PanelMetrics.checkColumn)
                    .padding(.trailing, PanelMetrics.checkGap)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                Spacer(minLength: 0)
            }
            .padding(.leading, PanelMetrics.rowLeading)
            .padding(.trailing, PanelMetrics.rowTrailing)
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .opacity(hovering ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
