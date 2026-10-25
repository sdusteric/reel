import AppKit
import ReelCore
import ReelUI
import UniformTypeIdentifiers

/// The Open panel and drag and drop (design 9.1). Which files are accepted is decided by
/// `SupportedMedia` in ReelUI, where it is tested.
enum OpenAndDrop {
    static var contentTypes: [UTType] {
        SupportedMedia.allExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// The Add Subtitle File panel's types: srt, ass, ssa, vtt (design 9.7).
    static var subtitleContentTypes: [UTType] {
        ExternalSubtitles.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// Shows the Open panel as a sheet on `window` and calls `open` with the chosen file.
    /// Never adds to the recent documents list.
    static func runOpenPanel(for window: NSWindow?, open: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = contentTypes
        panel.message = "Choose a video to play"
        run(panel, for: window) { urls in
            if let url = SupportedMedia.firstPlayable(in: urls) { open(url) }
        }
    }

    /// Add Subtitle File: starts in the video's folder.
    static func runSubtitlePanel(for window: NSWindow?, videoURL: URL?, choose: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = subtitleContentTypes
        panel.message = "Choose a subtitle file"
        if let folder = videoURL?.deletingLastPathComponent() { panel.directoryURL = folder }
        run(panel, for: window) { urls in
            if let url = urls.first(where: isSubtitleFile) { choose(url) }
        }
    }

    private static func run(_ panel: NSOpenPanel, for window: NSWindow?, finish: @escaping ([URL]) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            finish(panel.urls)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    static func isSubtitleFile(_ url: URL) -> Bool {
        url.isFileURL && ExternalSubtitles.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    /// What a drop carries: a video to open, or a subtitle file for the open video.
    enum DroppedFile: Equatable {
        case media(URL)
        case subtitle(URL)
    }

    static func droppedFile(in info: any NSDraggingInfo, acceptsSubtitles: Bool) -> DroppedFile? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        if let url = SupportedMedia.firstPlayable(in: urls) { return .media(url) }
        if acceptsSubtitles, let url = urls.first(where: isSubtitleFile) { return .subtitle(url) }
        return nil
    }
}

/// A view that accepts dropped media files and hands them to `onDrop`. While a video is open
/// (`acceptsSubtitles`), a dropped subtitle file goes to `onSubtitleDrop`.
class DropAcceptingView: NSView {
    var onDrop: ((URL) -> Void)?
    var onSubtitleDrop: ((URL) -> Void)?
    var acceptsSubtitles: () -> Bool = { false }
    /// Tells the empty state a valid file is over the window.
    var dropTarget: DropTargetState?

    func enableDrops() {
        registerForDraggedTypes(OpenAndDrop.draggedTypes)
    }

    private func operation(for info: any NSDraggingInfo) -> NSDragOperation {
        OpenAndDrop.droppedFile(in: info, acceptsSubtitles: acceptsSubtitles()) == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let result = operation(for: sender)
        dropTarget?.dragged(operation: result)
        return result
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let result = operation(for: sender)
        dropTarget?.dragged(operation: result)
        return result
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.exited()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.exited()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.concluded()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.performed()
        switch OpenAndDrop.droppedFile(in: sender, acceptsSubtitles: acceptsSubtitles()) {
        case .media(let url)?:
            guard let onDrop else { return false }
            onDrop(url)
            return true
        case .subtitle(let url)?:
            guard let onSubtitleDrop else { return false }
            onSubtitleDrop(url)
            return true
        case nil:
            return false
        }
    }
}
