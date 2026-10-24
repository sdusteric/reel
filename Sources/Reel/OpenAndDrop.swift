import AppKit
import ReelUI
import UniformTypeIdentifiers

/// The Open panel and drag and drop (design 9.1). Which files are accepted is decided by
/// `SupportedMedia` in ReelUI, where it is tested.
enum OpenAndDrop {
    static var contentTypes: [UTType] {
        SupportedMedia.allExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
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
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = SupportedMedia.firstPlayable(in: panel.urls) else { return }
            open(url)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    /// The playable file in a drag, if any.
    static func playableFile(in info: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return SupportedMedia.firstPlayable(in: urls)
    }

    static func dragOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        playableFile(in: info) == nil ? [] : .copy
    }
}

/// A view that accepts dropped media files and hands them to `onDrop`.
class DropAcceptingView: NSView {
    var onDrop: ((URL) -> Void)?

    func enableDrops() {
        registerForDraggedTypes(OpenAndDrop.draggedTypes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        OpenAndDrop.dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        OpenAndDrop.dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = OpenAndDrop.playableFile(in: sender), let onDrop else { return false }
        onDrop(url)
        return true
    }
}
