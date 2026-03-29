import Foundation
import AppKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "FileImportService")

struct FileImportService {

    static func openPanel(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .movie, .video, .mpeg4Movie, .quickTimeMovie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "avi") ?? .movie,
            UTType(filenameExtension: "ts")  ?? .movie,
        ]
        panel.begin { response in
            guard response == .OK else { return }
            logger.debug("Open panel: \(panel.urls.count) file(s) selected")
            completion(panel.urls)
        }
    }

    /// Accepts all URLs — actual playability is determined later by AVFoundation.
    static func filter(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL }
    }
}
