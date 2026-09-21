import Foundation

struct FFmpegInstallation: Equatable, Sendable {
    let ffmpeg: URL
    let ffprobe: URL
}

enum FFmpegLocator {
    static let standardDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func locate(fileManager: FileManager = .default) -> FFmpegInstallation? {
        for directory in standardDirectories {
            let ffmpeg = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            let ffprobe = URL(fileURLWithPath: directory).appendingPathComponent("ffprobe")
            if fileManager.isExecutableFile(atPath: ffmpeg.path) && fileManager.isExecutableFile(atPath: ffprobe.path) {
                return FFmpegInstallation(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }
}
