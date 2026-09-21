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

    /// Collects file URLs from a set of NSItemProviders (e.g. from `.onDrop`).
    @discardableResult
    static func extractURLs(
        from providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) -> Bool {
        guard !providers.isEmpty else { return false }
        var pending = providers.count
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                defer { lock.unlock() }
                if let url, url.isFileURL {
                    urls.append(url)
                }
                pending -= 1
                if pending == 0 {
                    let collected = urls
                    DispatchQueue.main.async {
                        if !collected.isEmpty { completion(collected) }
                    }
                }
            }
        }
        return true
    }
}
