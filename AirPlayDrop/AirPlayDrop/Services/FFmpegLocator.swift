import Foundation

struct FFmpegInstallation: Equatable, Sendable {
    let ffmpeg: URL
    let ffprobe: URL
}

struct FFmpegDiagnostics: Equatable, Sendable {
    let installation: FFmpegInstallation?
    let ffmpegVersion: String?
    let ffprobeVersion: String?
    let error: String?
}

enum FFmpegLocator {
    static let configuredDirectoryKey = "FFmpegBinaryDirectory"
    static let standardDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func locate(fileManager: FileManager = .default, defaults: UserDefaults = .standard,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> FFmpegInstallation? {
        var directories: [String] = []
        if let configured = defaults.string(forKey: configuredDirectoryKey), !configured.isEmpty {
            directories.append((configured as NSString).expandingTildeInPath)
        }
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += standardDirectories
        for directory in directories.reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let ffmpeg = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            let ffprobe = URL(fileURLWithPath: directory).appendingPathComponent("ffprobe")
            if fileManager.isExecutableFile(atPath: ffmpeg.path) && fileManager.isExecutableFile(atPath: ffprobe.path) {
                return FFmpegInstallation(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }

    static func saveConfiguredDirectory(_ directory: String, defaults: UserDefaults = .standard) {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { defaults.removeObject(forKey: configuredDirectoryKey) }
        else { defaults.set(value, forKey: configuredDirectoryKey) }
    }

    static func diagnose() async -> FFmpegDiagnostics {
        guard let installation = locate() else {
            return FFmpegDiagnostics(installation: nil, ffmpegVersion: nil, ffprobeVersion: nil,
                error: "FFmpeg and FFprobe were not found. Install them with Homebrew or choose their bin directory in Settings.")
        }
        do {
            async let ffmpeg = firstVersionLine(installation.ffmpeg)
            async let ffprobe = firstVersionLine(installation.ffprobe)
            let versions = try await (ffmpeg, ffprobe)
            return FFmpegDiagnostics(installation: installation, ffmpegVersion: versions.0,
                ffprobeVersion: versions.1, error: nil)
        } catch {
            return FFmpegDiagnostics(installation: installation, ffmpegVersion: nil, ffprobeVersion: nil,
                error: "The configured tools could not be executed: \(error.localizedDescription)")
        }
    }

    private static func firstVersionLine(_ executable: URL) async throws -> String {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["-version"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: "\n").first.map(String.init) ?? executable.lastPathComponent
        }.value
    }
}
