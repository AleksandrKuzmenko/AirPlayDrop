import Foundation
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "TranscodeService")

enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case noVideo
    case noAudioSelection
    case processFailed(Int32, String)
    case invalidOutput(String)
    case allStrategiesFailed(String)
    case externalSubtitleUnavailable(String)
    case audioFilterUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg and FFprobe were not found. Install them with Homebrew or choose their bin directory in Settings."
        case .noVideo: return "No video track was found in the source."
        case .noAudioSelection: return "The source contains audio, but no audio track is selected."
        case .processFailed(let code, let details):
            return "FFmpeg exited with code \(code). \(details)"
        case .invalidOutput(let reason): return "Generated media failed validation: \(reason)"
        case .allStrategiesFailed(let details): return "No conversion strategy succeeded. \(details)"
        case .externalSubtitleUnavailable(let details): return "The selected external subtitle is unavailable: \(details)"
        case .audioFilterUnavailable(let details): return "Late Night audio is unavailable: \(details)"
        }
    }
}

struct PreparedArtifact: Sendable {
    let url: URL
    let strategy: ConversionStrategy
    let reason: String
    let isAirPlayPrepared: Bool
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled { process.terminate() }
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

private final class BoundedDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private let limit = 16_384

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        value.append(text)
        if value.utf8.count > limit { value = String(value.suffix(limit)) }
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscodeService {
    static func isAudioFilterAvailable(using installation: FFmpegInstallation) async -> Bool {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = installation.ffmpeg
            process.arguments = ["-hide_banner", "-filters"]
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let text = String(decoding: data, as: UTF8.self)
            return ["acompressor", "alimiter"].allSatisfy { text.contains($0) }
        }.value
    }

    static func outputURL(for input: URL) -> URL {
        input.deletingLastPathComponent()
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_airplay.mp4")
    }

    static func streamArguments(selection: TrackSelection, sourceHasAudio: Bool) throws -> [String] {
        try streamArguments(selection: selection, sourceHasAudio: sourceHasAudio, hasExternalSubtitleInput: false)
    }

    static func streamArguments(selection: TrackSelection, sourceHasAudio: Bool,
                                hasExternalSubtitleInput: Bool) throws -> [String] {
        if sourceHasAudio && selection.audioID == nil { throw TranscodeError.noAudioSelection }
        var arguments = ["-map", "0:v:0"]
        if let audioID = selection.audioID { arguments += ["-map", "0:\(audioID)"] }
        if selection.subtitlePolicy == .includeSelected {
            switch selection.subtitle {
            case .embedded(let subtitleID): arguments += ["-map", "0:\(subtitleID)"]
            case .external:
                guard hasExternalSubtitleInput else {
                    throw TranscodeError.externalSubtitleUnavailable("the sidecar input was not added")
                }
                arguments += ["-map", "1:0"]
            case .none: break
            }
        }
        arguments += ["-map_metadata", "-1", "-map_chapters", "-1", "-dn"]
        if selection.subtitlePolicy == .omit || selection.subtitle.isNone { arguments.append("-sn") }
        return arguments
    }

    static func ffmpegArguments(input: URL, output: URL, step: ConversionStep,
                                selection: TrackSelection, sourceHasAudio: Bool,
                                syncAdjustment: SyncAdjustment = .zero,
                                mediaDuration: Double? = nil) throws -> [String] {
        var arguments = ["-nostats", "-progress", "pipe:2", "-i", input.path]
        if case .external(let descriptor) = selection.subtitle,
           selection.subtitlePolicy == .includeSelected {
            guard descriptor.isCurrent else {
                throw TranscodeError.externalSubtitleUnavailable("\(descriptor.displayName) changed or was removed")
            }
            // External subtitle input is the second input, so -itsoffset is
            // placed immediately before that -i. It shifts only sidecar cues;
            // the first input's video timestamps remain unchanged.
            let offset = Double(syncAdjustment.subtitleMilliseconds) / 1000
            if offset != 0 { arguments += ["-itsoffset", String(format: "%.3f", offset)] }
            arguments += ["-i", descriptor.standardizedURL.path]
        }
        arguments += try streamArguments(selection: selection, sourceHasAudio: sourceHasAudio,
                                         hasExternalSubtitleInput: selection.subtitle.externalDescriptor != nil)
        arguments += step.videoArguments
        if selection.audioID != nil { arguments += step.audioArguments }
        if selection.audioID != nil,
           let filter = audioFilter(for: syncAdjustment, mode: step.audioProcessingMode,
                                    mediaDuration: mediaDuration) {
            arguments += ["-af", filter]
        }
        if selection.subtitlePolicy == .includeSelected, !selection.subtitle.isNone {
            arguments += ["-c:s", "mov_text"]
            if syncAdjustment.subtitleMilliseconds != 0,
               selection.subtitle.externalDescriptor == nil {
                // Embedded mov_text cues use the setts bitstream filter. The
                // -10s...+10s clamp prevents an unbounded timestamp shift.
                let seconds = Double(syncAdjustment.subtitleMilliseconds) / 1000
                arguments += ["-bsf:s", "setts=ts=PTS+\(String(format: "%.3f", seconds))/TB"]
            }
        }
        arguments += ["-movflags", "+faststart", output.path]
        return arguments
    }

    static func audioFilter(for adjustment: SyncAdjustment,
                            mode: AudioProcessingMode = .standard,
                            mediaDuration: Double? = nil) -> String? {
        var filters: [String] = []
        if adjustment.audioMilliseconds > 0 {
            // Positive offsets delay only the selected audio.
            filters.append("adelay=\(adjustment.audioMilliseconds):all=1")
            // adelay adds leading silence and would otherwise extend the MP4
            // past the video. Trim to the probed media duration when known.
            if let mediaDuration, mediaDuration.isFinite, mediaDuration > 0 {
                filters.append("atrim=end=\(String(format: "%.3f", mediaDuration))")
            }
        } else if adjustment.audioMilliseconds < 0 {
            filters.append("atrim=start=\(String(format: "%.3f", Double(-adjustment.audioMilliseconds) / 1000)),asetpts=PTS-STARTPTS")
        }
        if mode == .lateNight { filters.append(AudioProcessingPreset.lateNightFilter) }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    static func prepare(input: URL, info: MediaInfo, selection: TrackSelection,
                        intent: PlaybackIntent, syncAdjustment: SyncAdjustment = .zero,
                        audioProcessingMode: AudioProcessingMode = .standard,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedArtifact {
        guard info.videoCodec != nil else { throw TranscodeError.noVideo }
        guard let installation = FFmpegLocator.locate() else { throw TranscodeError.ffmpegNotFound }
        if audioProcessingMode == .lateNight,
           !(await isAudioFilterAvailable(using: installation)) {
            throw TranscodeError.audioFilterUnavailable("the installed FFmpeg does not expose acompressor and alimiter")
        }
        let plan = TranscodePlanner.plan(info: info, intent: intent, selectedAudioID: selection.audioID,
                                         audioProcessingMode: audioProcessingMode,
                                         syncAdjustment: syncAdjustment,
                                         requiresSubtitleMuxing: selection.hasSelectedSubtitle)
        if plan.steps.isEmpty {
            return PreparedArtifact(url: input, strategy: .directPlay, reason: plan.reason, isAirPlayPrepared: false)
        }

        let reservation = try OutputReservation.reserve(for: input)
        var failures: [String] = []
        defer { try? FileManager.default.removeItem(at: reservation.temporary) }

        for step in plan.steps {
            try Task.checkCancellation()
            progress(0)
            logger.notice("[\(step.strategy.rawValue)] \(step.reason)")
            do {
                let arguments = try ffmpegArguments(input: input, output: reservation.temporary,
                    step: step, selection: selection, sourceHasAudio: info.hasAudio,
                    syncAdjustment: syncAdjustment, mediaDuration: info.duration)
                try await runProcess(executable: installation.ffmpeg, arguments: arguments,
                    duration: info.duration, progress: progress)
                try Task.checkCancellation()
                let validation = await MediaArtifactValidator.validate(reservation.temporary,
                    sourceHadAudio: info.hasAudio, expectedDuration: info.duration, requiresHVC1: step.requiresHVC1)
                guard validation.isValid else {
                    throw TranscodeError.invalidOutput(validation.reason ?? "Unknown validation error")
                }
                try FileManager.default.moveItem(at: reservation.temporary, to: reservation.destination)
                do {
                    try MediaArtifactValidator.writeManifest(source: input, artifact: reservation.destination,
                        sourceHadAudio: info.hasAudio, selectedAudioID: selection.audioID,
                        expectedDuration: info.duration, requiresHVC1: step.requiresHVC1,
                        selectedSubtitle: selection.subtitle, syncAdjustment: syncAdjustment,
                        audioProcessingMode: audioProcessingMode, playbackIntent: intent)
                } catch {
                    try? FileManager.default.removeItem(at: reservation.destination)
                    throw error
                }
                progress(1)
                return PreparedArtifact(url: reservation.destination, strategy: step.strategy,
                    reason: step.reason, isAirPlayPrepared: intent == .airPlay)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(step.strategy.rawValue): \(error.localizedDescription)")
                logger.warning("[\(step.strategy.rawValue)] failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: reservation.temporary)
            }
        }
        throw TranscodeError.allStrategiesFailed(failures.suffix(2).joined(separator: " "))
    }

    static func runProcess(executable: URL, arguments: [String], duration: Double?,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let holder = RunningProcess()
        let diagnostics = BoundedDiagnostics()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = pipe
                holder.install(process)

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    diagnostics.append(text)
                    guard let duration, duration > 0 else { return }
                    for line in text.split(whereSeparator: \.isNewline) {
                        if let seconds = parseOutTime(String(line)) {
                            progress(min(max(seconds / duration, 0), 0.99))
                        }
                    }
                }
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !tail.isEmpty { diagnostics.append(String(decoding: tail, as: UTF8.self)) }
                    if holder.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: TranscodeError.processFailed(process.terminationStatus,
                            diagnostics.snapshot()))
                    }
                }
                do {
                    try process.run()
                    if holder.wasCancelled { holder.terminate() }
                }
                catch { pipe.fileHandleForReading.readabilityHandler = nil; continuation.resume(throwing: error) }
            }
        }, onCancel: {
            holder.terminate()
        })
    }

    static func parseOutTime(_ line: String) -> Double? {
        if line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst("out_time_us=".count)) {
            return microseconds / 1_000_000
        }
        if line.hasPrefix("out_time_ms="), let microseconds = Double(line.dropFirst("out_time_ms=".count)) {
            return microseconds / 1_000_000
        }
        guard line.hasPrefix("out_time=") else { return nil }
        let fields = line.dropFirst("out_time=".count).split(separator: ":")
        guard fields.count == 3, let h = Double(fields[0]), let m = Double(fields[1]), let s = Double(fields[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
