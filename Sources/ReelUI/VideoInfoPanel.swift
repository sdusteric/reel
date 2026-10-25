import ReelCore
import SwiftUI

/// The rows of Video Info in their four groups (design 9.13): Video and Decoder; Range, Colour,
/// Mastering and Light level; Display and Headroom; Audio and Frames. Pure, so tests can check
/// the lines for a file without drawing.
enum VideoInfoContent {
    static let headroomKey = "Headroom"

    static func groups(
        media: MediaInfo?,
        plan: DynamicRangePlan,
        decoder: VideoDecoderKind?,
        droppedFrames: Int,
        damagedCount: Int,
        audioStreamIndex: Int?
    ) -> [[VideoInfoRow]] {
        let stream = media?.videoStream
        var video: [VideoInfoRow] = []
        if let stream {
            video.append(VideoInfoRow(key: "Video", value: videoText(stream)))
        }
        if let decoder {
            video.append(VideoInfoRow(key: "Decoder", value: decoderText(decoder, codec: stream?.codec)))
        }

        var range: [VideoInfoRow] = []
        if let first = plan.videoInfo.first { range.append(first) }
        let color = stream?.video?.color
        let hasColor = color?.primaries != nil || color?.transfer != nil
        range.append(VideoInfoRow(key: "Colour", value: hasColor ? (color?.videoInfoDescription ?? "") : "Unspecified"))
        if let mastering = color?.mastering {
            range.append(VideoInfoRow(key: "Mastering", value: mastering.videoInfoDescription))
        }
        if let light = color?.contentLight {
            range.append(VideoInfoRow(key: "Light level", value: light.videoInfoDescription))
        }

        let display = Array(plan.videoInfo.dropFirst())

        var tail = [VideoInfoRow(key: "Audio", value: audioText(media, selected: audioStreamIndex))]
        tail.append(VideoInfoRow(key: "Frames", value: "\(droppedFrames) dropped, \(damagedCount) damaged"))

        return [video, range, display, tail].filter { !$0.isEmpty }
    }

    /// "HEVC Main 10, 3840 \u{00D7} 2160, 23.976 fps".
    static func videoText(_ stream: StreamInfo) -> String {
        var codec = MediaProblem.displayCodecName(stream.codec)
        if codec == stream.codec { codec = codec.uppercased() }
        if let profile = stream.profile, !profile.isEmpty {
            codec += " \(profile)"
        } else if let depth = stream.video?.bitDepth, depth > 8 {
            codec += " \(depth)-bit"
        }
        var parts = [codec]
        if let video = stream.video {
            parts.append("\(video.width) \u{00D7} \(video.height)")
            if let rate = video.frameRate, rate.isValid { parts.append("\(frameRateText(rate.doubleValue)) fps") }
        }
        return parts.joined(separator: ", ")
    }

    /// 24 gives "24", 24000/1001 gives "23.976", 30000/1001 gives "29.97".
    static func frameRateText(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.0005 { return "\(Int(value.rounded()))" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func decoderText(_ decoder: VideoDecoderKind, codec: String?) -> String {
        switch decoder {
        case .hardware: "VideoToolbox, hardware"
        case .software: codec == "av1" ? "dav1d, software" : "libavcodec, software"
        }
    }

    /// "E-AC-3 5.1, 48 kHz".
    static func audioText(_ media: MediaInfo?, selected: Int?) -> String {
        guard let media else { return "None" }
        let stream = media.streams.first { $0.kind == .audio && $0.index == selected }
            ?? media.streams.first { $0.kind == .audio }
        guard let stream, let track = AudioTrack(stream: stream) else { return "None" }
        guard let rate = stream.audio?.sampleRate, rate > 0 else { return track.formatTag }
        let khz = Double(rate) / 1_000
        let text = khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)
        return "\(track.formatTag), \(text) kHz"
    }
}

/// Video Info (design 9.13, mockup png/20): a read-only panel on the material, top right, under
/// the title scrim. Values change in place; nothing animates.
struct VideoInfoPanel: View {
    static let width: CGFloat = 344
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 6
    static let rightInset: CGFloat = 20
    static let topInset: CGFloat = 48
    static let keyWidth: CGFloat = 92
    static let meterHeight: CGFloat = 4

    let model: PlayerModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let groups = model.videoInfoGroups
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(groups.enumerated()), id: \.offset) { index, rows in
                if index > 0 { PanelSeparator() }
                ForEach(rows, id: \.key) { row in
                    InfoRow(row: row, meter: row.key == VideoInfoContent.headroomKey ? model.displayCapabilities.headroomFraction : nil)
                }
            }
        }
        .padding(VideoInfoPanel.padding)
        .frame(width: VideoInfoPanel.width)
        .continuousSurface(radius: VideoInfoPanel.cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video Info")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Video Info")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.9))
            Spacer(minLength: 8)
            Text("\u{2318}I")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChromeStyle.tagText(colorScheme))
        }
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

private struct InfoRow: View {
    let row: VideoInfoRow
    var meter: Double?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.key)
                .font(.system(size: 12))
                .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
                .frame(width: VideoInfoPanel.keyWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.value)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ChromeStyle.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let meter {
                    HeadroomMeter(fraction: meter)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.key), \(row.value)" + (row.detail.map { ". \($0)" } ?? ""))
    }
}

/// The 4 pt headroom meter: current over potential headroom. Never animated.
private struct HeadroomMeter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: max(VideoInfoPanel.meterHeight, proxy.size.width * fraction))
            }
        }
        .frame(height: VideoInfoPanel.meterHeight)
    }
}
