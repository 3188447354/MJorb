import Foundation

/// A share-sheet route exists only after the export has been materialized.
struct LogExportDocument: Identifiable {
    let url: URL

    var id: URL { url }

    init?(url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        self.url = url
    }
}
