import Foundation
import Observation

// @unchecked Sendable: all mutations occur on @MainActor; the class itself is not
// actor-isolated, but access patterns in this app guarantee main-thread safety.
@Observable
final class MediaItem: Identifiable, @unchecked Sendable {
    let id: UUID
    let fileURL: URL        // original source; never changes
    var transcodedURL: URL? // set by TranscodeService on success
    var displayName: String
    var duration: Double?   // seconds, best-effort
    var state: MediaItemState
    var formatFlags: Set<VideoFormatFlag> = []
    var isAirPlayPrepared = false
    var mediaInfo: MediaInfo?
    var trackSelection = TrackSelection()
    var hasAppliedInitialSelection = false
    var playbackIntent: PlaybackIntent = .local
    var syncAdjustment = SyncAdjustment()
    var audioProcessingMode: AudioProcessingMode = .standard
    var preparationReason: String?

    /// HDR/DV needs an explicitly AirPlay-safe conversion. A generic remux may
    /// produce an MP4 while retaining Dolby Vision RPU data, an `hev1` sample
    /// entry, or other stream metadata that Apple TV cannot consume.
    ///
    /// Video the Mac plays but the Apple TV cannot decode, such as 10-bit or
    /// 4:2:2 H.264, HEVC range extensions, AV1, or anything above 2160p60,
    /// also needs a conversion. AVFoundation reports such HEVC sources as
    /// AirPlay-prepared, so only a copy made by an AirPlay plan for the same
    /// receiver skips the check.
    func needsAirPlayTranscode(for receiver: AirPlayReceiver) -> Bool {
        if hasAirPlayPreparedCopy(for: receiver) { return false }
        if !playedVideoIsCompatible(with: receiver) { return true }
        return !isAirPlayPrepared && !effectiveFormatFlags.isEmpty
    }

    /// FFprobe information for a prepared copy, probed after preparation. It
    /// applies only while that copy is the one being played.
    var preparedCopyInfo: (url: URL, info: MediaInfo)?

    /// The AirPlay receiver an AirPlay-prepared copy was made for.
    var preparedReceiver: AirPlayReceiver?

    /// Judges the file AVPlayer will stream: a probed prepared copy when there
    /// is one (a local H.264 encode of a VP9 source is already compatible),
    /// otherwise the source.
    func playedVideoIsCompatible(with receiver: AirPlayReceiver) -> Bool {
        if let transcodedURL, let copy = preparedCopyInfo, copy.url == transcodedURL {
            return AppleTVVideoCompatibility.isCompatible(copy.info, receiver: receiver)
        }
        guard let mediaInfo else { return true }
        return AppleTVVideoCompatibility.isCompatible(mediaInfo, receiver: receiver)
    }

    func hasAirPlayPreparedCopy(for receiver: AirPlayReceiver) -> Bool {
        isAirPlayPrepared && playbackIntent == .airPlay && transcodedURL != nil
            && (preparedReceiver ?? .appleTV4K) == receiver
    }

    /// HDR/DV markers from AVFoundation combined with those from FFprobe.
    /// AVFoundation inspects only sources it can open, so containers such as
    /// MKV report their HDR/DV status through FFprobe alone.
    var effectiveFormatFlags: Set<VideoFormatFlag> {
        formatFlags.union(mediaInfo?.formatFlags ?? [])
    }

    var formatTag: String? {
        let flags = effectiveFormatFlags
        if flags.contains(.dolbyVision) { return "DV" }
        if flags.contains(.hdr10)       { return "HDR" }
        if flags.contains(.hlg)         { return "HLG" }
        return nil
    }

    /// URL handed to AVPlayer — prefers the transcoded copy when available.
    var playbackURL: URL { transcodedURL ?? fileURL }

    var selectedAudio: MediaTrack? {
        mediaInfo?.audioTracks.first { $0.id == trackSelection.audioID }
    }

    var selectedExternalSubtitle: ExternalSubtitleDescriptor? {
        trackSelection.subtitle.externalDescriptor
    }

    init(fileURL: URL) {
        self.id = UUID()
        self.fileURL = fileURL
        self.transcodedURL = nil
        self.displayName = fileURL.deletingPathExtension().lastPathComponent
        self.duration = nil
        self.state = .idle
    }

    var durationString: String? {
        guard let d = duration, d > 0 else { return nil }
        let total = Int(d)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
