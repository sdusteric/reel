import Foundation
import ReelCore

/// `reelctl episodes <file> [--json]`: the folder's episode order (natural sort, hidden,
/// AppleDouble and non-video files excluded), the file's index, next and previous.
enum EpisodesCommand {
    struct Report: Encodable {
        var file: String
        var folder: String
        var name: String
        var episodes: [String]
        var count: Int
        var index: Int?
        var next: String?
        var previous: String?
    }

    static func run(_ arguments: CommandArguments) throws -> Int32 {
        let file = try arguments.file()
        let list = try EpisodeList.scan(current: file)
        let report = Report(
            file: file.lastPathComponent,
            folder: file.deletingLastPathComponent().path(percentEncoded: false),
            name: EpisodeList.episodeName(for: file),
            episodes: list.files.map(\.lastPathComponent),
            count: list.count,
            index: list.currentIndex,
            next: list.next?.lastPathComponent,
            previous: list.previous?.lastPathComponent
        )
        if arguments.json {
            try printJSON(report)
        } else {
            for (index, episode) in report.episodes.enumerated() {
                print("\(index == report.index ? "*" : " ") \(episode)")
            }
            print("next: \(report.next ?? "none")")
            print("previous: \(report.previous ?? "none")")
        }
        return 0
    }
}
