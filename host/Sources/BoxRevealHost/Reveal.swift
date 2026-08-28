import AppKit
import Foundation

enum Reveal {
    /// Selects the item in Finder inside its parent window — the `open -R`
    /// behavior, rather than opening the folder itself.
    static func inFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
