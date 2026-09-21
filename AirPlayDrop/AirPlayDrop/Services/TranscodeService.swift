import Foundation
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "TranscodeService")

// MARK: - Errors

enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case processFailed(Int32)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg not found. Install with: brew install ffmpeg"
        case .processFailed(let code):
            return "FFmpeg exited with code \(code). Check Console for details."
        case .invalidOutput(let reason):
            return "Generated media failed validation: \(reason)"
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

    /// Returns the first conventional output path. Actual jobs reserve a unique path and never
    /// overwrite this value; this method remains for display and compatibility with older callers.
    static func outputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(stem + "_airplay.mp4")
    }

    // MARK: - Main entry point (called from @MainActor context)

    /// Tries strategies in order from `startingAt` up to (not including) `endBefore`.
    /// Marks the item `.ready` on first success.
    /// When `endBefore` is less than the total strategy count the item is NOT marked `.failed`
    /// on exhaustion — the caller is expected to try remaining strategies after (e.g. after
    /// asking the user for permission to do a slow video re-encode).
    @MainActor
    static func process(item: MediaItem, startingAt: Int = 0, endBefore: Int = .max) async {
        guard let ffmpeg = findFFmpeg() else {
            item.state = .failed(TranscodeError.ffmpegNotFound.localizedDescription)
            return
        }

        let reservation: OutputReservation
        do { reservation = try OutputReservation.reserve(for: item.fileURL) }
        catch { item.state = .failed("Could not reserve an output file: \(error.localizedDescription)"); return }

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
            // 0: remux — repackage unchanged streams, instant, lossless.
            ("remux",                ["-c", "copy"]),
            // 1: audio-transcode — copy video, re-encode audio to AAC. Handles DTS/TrueHD/EAC3.
            ("audio-transcode",      ["-c:v", "copy", "-c:a", "aac", "-ac:a", "2",
                                      "-b:a", "192k"]),
            // 2: hw-video-transcode — VideoToolbox H.264 (GPU/media engine, fast).
            //    Handles HEVC/VP9/AV1 that VideoToolbox can't decode for playback.
            ("hw-video-transcode",   ["-c:v", "h264_videotoolbox", "-b:v", "5000k",
                                      "-c:a", "aac", "-ac:a", "2", "-b:a", "192k"]),
            // 3: sw-video-transcode — libx264 software fallback, handles anything FFmpeg decodes.
            ("sw-video-transcode",   ["-c:v", "libx264", "-preset", "fast", "-crf", "20",
                                      "-c:a", "aac", "-ac:a", "2", "-b:a", "192k"]),
        ]

        let start = min(startingAt, strategies.count)
        let end   = min(endBefore,   strategies.count)
        for strategy in strategies[start..<end] {
            guard !Task.isCancelled else { return }

            item.state = .transcoding(0.0)
            logger.debug("[\(strategy.name)] starting: '\(item.displayName)'")

            do {
                try await runFFmpeg(
                    ffmpeg: ffmpeg,
                    input: item.fileURL,
                    output: reservation.temporary,
                    codecArgs: strategy.codecArgs,
                    item: item
                )
                let validation = await MediaArtifactValidator.validate(reservation.temporary)
                guard validation.isValid else { throw TranscodeError.invalidOutput(validation.reason ?? "Output validation failed") }
                try FileManager.default.moveItem(at: reservation.temporary, to: reservation.destination)
                item.transcodedURL = reservation.destination
                item.state = .ready
                logger.debug("[\(strategy.name)] done: '\(item.displayName)'")
                return
            } catch {
                logger.warning("[\(strategy.name)] failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: reservation.temporary)
            }
        }

        guard !Task.isCancelled else { return }
        // Only mark permanently failed when we've run through all remaining strategies.
        // When endBefore limits the range, the caller will handle what to try next.
        if end >= strategies.count {
            item.state = .failed("No transcode strategy succeeded. Check Console for details.")
        }
    }

    /// Produces an Apple TV friendly HDR10 MP4 from an HDR/Dolby Vision source.
    ///
    /// The fast path keeps the HEVC Main 10 HDR10-compatible base layer and removes
    /// Dolby Vision RPU NAL units (type 62). If the source cannot be remuxed, the
    /// fallback re-encodes to HEVC Main 10 with VideoToolbox while preserving the
    /// BT.2020/PQ HDR signalling.
    @MainActor
    static func processForAirPlay(item: MediaItem) async {
        guard let ffmpeg = findFFmpeg() else {
            item.state = .failed(TranscodeError.ffmpegNotFound.localizedDescription)
            return
        }

        let reservation: OutputReservation
        do { reservation = try OutputReservation.reserve(for: item.fileURL) }
        catch { item.state = .failed("Could not reserve an output file: \(error.localizedDescription)"); return }

        let streamArgs = [
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-map_metadata", "-1",
            "-map_chapters", "-1",
            "-sn", "-dn",
        ]
        let strategies: [(name: String, codecArgs: [String])] = [
            (
                "airplay-hdr10-remux",
                streamArgs + [
                    "-c:v", "copy",
                    "-bsf:v", "filter_units=remove_types=62",
                    "-tag:v", "hvc1",
                    "-c:a", "aac", "-ac:a", "2", "-b:a", "192k",
                ]
            ),
            (
                "airplay-hdr10-videotoolbox",
                streamArgs + [
                    "-c:v", "hevc_videotoolbox",
                    "-profile:v", "main10",
                    "-pix_fmt", "p010le",
                    "-b:v", "12000k",
                    "-tag:v", "hvc1",
                    "-c:a", "aac", "-ac:a", "2", "-b:a", "192k",
                ]
            ),
        ]

        for strategy in strategies {
            guard !Task.isCancelled else { return }
            item.state = .transcoding(0)
            logger.debug("[\(strategy.name)] starting: '\(item.displayName)'")

            do {
                try await runFFmpeg(
                    ffmpeg: ffmpeg,
                    input: item.fileURL,
                    output: reservation.temporary,
                    codecArgs: strategy.codecArgs,
                    item: item
                )
                let validation = await MediaArtifactValidator.validate(reservation.temporary)
                guard validation.isValid else { throw TranscodeError.invalidOutput(validation.reason ?? "Output validation failed") }
                try FileManager.default.moveItem(at: reservation.temporary, to: reservation.destination)
                item.transcodedURL = reservation.destination
                item.isAirPlayPrepared = true
                item.state = .ready
                logger.debug("[\(strategy.name)] done: '\(item.displayName)'")
                return
            } catch {
                logger.warning("[\(strategy.name)] failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: reservation.temporary)
            }
        }

        guard !Task.isCancelled else { return }
        item.state = .failed("Could not create an Apple TV compatible HDR10 copy.")
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
            "-nostats", "-progress", "pipe:2",
            "-i", input.path,
        ] + codecArgs + ["-movflags", "+faststart", output.path]

        logger.debug("exec: ffmpeg \(argv.joined(separator: " "))")

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = argv
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe

        // Captured as var so the readabilityHandler can fill it in from FFmpeg's
        // header if AVFoundation didn't provide a duration (item.duration == nil).
        var effectiveDuration = item.duration ?? 0
        // Accumulates stderr so we can log it on failure for diagnosis.
        var stderrLog = ""

        // Wire up real-time progress via readabilityHandler (background thread → @MainActor).
        errPipe.fileHandleForReading.readabilityHandler = { [weak item] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }

            stderrLog += text

            for line in text.components(separatedBy: .newlines) {
                // Fallback: grab total duration from FFmpeg's "  Duration: HH:MM:SS.ss, ..."
                // header line when AVFoundation couldn't provide it.
                if effectiveDuration <= 0, let d = parseDuration(line) {
                    effectiveDuration = d
                    Task { @MainActor [weak item] in item?.duration = d }
                }

                guard effectiveDuration > 0, let secs = parseOutTime(line) else { continue }
                let progress = min(secs / effectiveDuration, 0.99)
                Task { @MainActor [weak item] in
                    if case .transcoding = item?.state {
                        item?.state = .transcoding(progress)
                    }
                }
            }
        }

        // Launch and await termination. withTaskCancellationHandler ensures the FFmpeg
        // subprocess is killed if the Swift Task is cancelled — prevents two concurrent
        // FFmpeg processes from writing to the same output file.
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
        } onCancel: {
            process.terminate()
        }

        guard exitCode == 0 else {
            logger.error("FFmpeg exited \(exitCode), stderr:\n\(stderrLog)")
            throw TranscodeError.processFailed(exitCode)
        }
    }

    // MARK: - Progress parsing

    /// Parses `  Duration: HH:MM:SS.ss, ...` from FFmpeg's input-info header.
    private static func parseDuration(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Duration:") else { return nil }
        let ts = trimmed.dropFirst("Duration:".count)
            .trimmingCharacters(in: .whitespaces)
            .prefix(while: { $0 != "," && !$0.isWhitespace })
        let parts = ts.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        let total = h * 3600 + m * 60 + s
        return total > 0 ? total : nil
    }

    /// Parses `out_time=HH:MM:SS.ssssss` from an FFmpeg `-progress` line.
    private static func parseOutTime(_ line: String) -> Double? {
        guard line.hasPrefix("out_time=") else { return nil }
        let ts = line.dropFirst("out_time=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines) // strip \r if present
        let parts = ts.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        let total = h * 3600 + m * 60 + s
        return total > 0 ? total : nil
    }
}
