import Foundation
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "TranscodeService")

// MARK: - Errors

enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case processFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg not found. Install with: brew install ffmpeg"
        case .processFailed(let code):
            return "FFmpeg exited with code \(code). Check Console for details."
        }
    }
}

// MARK: - Service

struct TranscodeService {

    private static let knownPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    static func findFFmpeg() -> URL? {
        knownPaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var scratchDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirPlayDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Main entry point (called from @MainActor context)

    /// Tries three strategies in order and marks the item .ready on first success.
    @MainActor
    static func process(item: MediaItem) async {
        guard let ffmpeg = findFFmpeg() else {
            item.state = .failed(TranscodeError.ffmpegNotFound.localizedDescription)
            return
        }

        let output = scratchDirectory.appendingPathComponent("\(item.id.uuidString).mp4")
        try? FileManager.default.removeItem(at: output)

        // Strategy cascade — fastest / highest quality first.
        //
        //  remux           — repackage unchanged streams into MP4 container.
        //                    Instant, lossless. Fails when a codec (e.g. DTS) is
        //                    not legal inside MP4.
        //
        //  audio-transcode — copy video track, re-encode audio to AAC.
        //                    Fast. Handles DTS / TrueHD / E-AC3 / Opus.
        //
        //  full-transcode  — re-encode both video (H.264) and audio (AAC).
        //                    Slow. Handles anything ffmpeg can decode.

        let strategies: [(name: String, codecArgs: [String])] = [
            ("remux",           ["-c", "copy"]),
            ("audio-transcode", ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]),
            ("full-transcode",  ["-c:v", "libx264", "-preset", "fast", "-crf", "20",
                                 "-c:a", "aac", "-b:a", "192k"]),
        ]

        for strategy in strategies {
            guard !Task.isCancelled else { return }

            item.state = .transcoding(0.0)
            logger.debug("[\(strategy.name)] starting: '\(item.displayName)'")

            do {
                try await runFFmpeg(
                    ffmpeg: ffmpeg,
                    input: item.fileURL,
                    output: output,
                    codecArgs: strategy.codecArgs,
                    item: item
                )
                // Success — hand the transcoded URL back to the item on @MainActor.
                item.transcodedURL = output
                item.state = .ready
                logger.debug("[\(strategy.name)] done: '\(item.displayName)'")
                return
            } catch {
                logger.warning("[\(strategy.name)] failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: output)
            }
        }

        guard !Task.isCancelled else { return }
        item.state = .failed("No transcode strategy succeeded. Check Console for details.")
    }

    // MARK: - FFmpeg subprocess

    private static func runFFmpeg(
        ffmpeg: URL,
        input: URL,
        output: URL,
        codecArgs: [String],
        item: MediaItem
    ) async throws {
        // -nostats     : suppress the inline stats overlay (uses \r — hard to parse)
        // -progress p:2: write structured key=value progress to stderr once per second
        let argv: [String] = [
            "-y", "-nostats", "-progress", "pipe:2",
            "-i", input.path,
        ] + codecArgs + ["-movflags", "+faststart", output.path]

        logger.debug("exec: ffmpeg \(argv.joined(separator: " "))")

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = argv
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe

        let duration = item.duration ?? 0

        // Wire up real-time progress via readabilityHandler (background thread → @MainActor).
        errPipe.fileHandleForReading.readabilityHandler = { [weak item] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  duration > 0 else { return }

            for line in text.components(separatedBy: "\n") {
                guard let secs = parseOutTime(line) else { continue }
                let progress = min(secs / duration, 0.99)
                Task { @MainActor [weak item] in
                    if case .transcoding = item?.state {
                        item?.state = .transcoding(progress)
                    }
                }
            }
        }

        // Launch and await termination via terminationHandler + continuation.
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard exitCode == 0 else {
            throw TranscodeError.processFailed(exitCode)
        }
    }

    // MARK: - Progress parsing

    /// Parses `out_time=HH:MM:SS.ssssss` from an FFmpeg `-progress` line.
    private static func parseOutTime(_ line: String) -> Double? {
        guard line.hasPrefix("out_time=") else { return nil }
        let ts = line.dropFirst("out_time=".count) // "HH:MM:SS.ssssss" or "N/A"
        let parts = ts.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        let total = h * 3600 + m * 60 + s
        return total > 0 ? total : nil
    }
}
