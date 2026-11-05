import Foundation

#if os(macOS)
import AppKit
#endif

/// The system's folder chooser, for the one place a sandboxed Mac app has to
/// ask: Aonsoku Desktop's data folder lives outside the app's container.
///
/// The panel runs in the system's process, and the URL it returns carries read
/// access for this session only (`files.user-selected.read-only`). Nothing is
/// bookmarked, so the next launch asks again. iOS never shows the rows that
/// call this; it answers nil.
@MainActor
enum AppFolderPicker {
    /// - Parameters:
    ///   - message: the line above the file list.
    ///   - prompt: the confirm button's title.
    ///   - directory: where the panel opens. Hidden items are shown, since the
    ///     folders a user looks for here are below `~/Library`.
    /// - Returns: the chosen folder, or nil when the user cancelled.
    static func chooseFolder(
        message: String,
        prompt: String,
        startingAt directory: URL?
    ) async -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.showsHiddenFiles = true
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = directory

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK else { return nil }
        return panel.url
        #else
        return nil
        #endif
    }
}
