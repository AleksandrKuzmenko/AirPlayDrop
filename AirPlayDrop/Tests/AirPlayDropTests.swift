import XCTest
import CoreGraphics
import AVFoundation
@testable import AirPlayDrop

final class AirPlayDropTests: XCTestCase {
    private func info(format: String? = "matroska,webm", video: String = "hevc", audio: String? = "aac",
                      hdr: Bool = false, dolbyVision: Bool = false) -> MediaInfo {
        var tracks = [MediaTrack(id: 0, kind: .video, codec: video, language: nil, title: nil,
            channels: nil, isDefault: true, isTextSubtitle: false)]
        if let audio {
            tracks.append(MediaTrack(id: 2, kind: .audio, codec: audio, language: "eng", title: "English",
                channels: 6, isDefault: true, isTextSubtitle: false))
        }
        let h264 = video == "h264"
        return MediaInfo(formatName: format, duration: 120, videoCodec: video,
            videoProfile: h264 ? "High" : "Main 10", pixelFormat: h264 ? "yuv420p" : "yuv420p10le",
            colorTransfer: hdr ? "smpte2084" : nil,
            isDolbyVision: dolbyVision, tracks: tracks)
    }

    func testParseDecoderNamesReadsFFmpegDecoderTable() {
        let text = """
        Decoders:
         V..... = Video
         A..... = Audio
         ------
         V....D av1                  Alliance for Open Media AV1
         V....D libdav1d             dav1d AV1 decoder by VideoLAN (codec av1)
         VFS..D hevc                 HEVC (High Efficiency Video Coding)
         A....D truehd               TrueHD
        """
        let names = TranscodeService.parseDecoderNames(text)
        XCTAssertEqual(names, ["av1", "libdav1d", "hevc", "truehd"])
    }

    func testAV1PrefersSoftwareDecoderThenHardwareAccelerator() throws {
        XCTAssertEqual(try TranscodeService.inputDecoderArguments(videoCodec: "av1",
            hasSoftwareAV1Decoder: true, hasHardwareAV1Decoder: true), [])
        XCTAssertEqual(try TranscodeService.inputDecoderArguments(videoCodec: "av1",
            hasSoftwareAV1Decoder: false, hasHardwareAV1Decoder: true), ["-hwaccel", "videotoolbox"])
        XCTAssertThrowsError(try TranscodeService.inputDecoderArguments(videoCodec: "av1",
            hasSoftwareAV1Decoder: false, hasHardwareAV1Decoder: false)) { error in
            guard case TranscodeError.av1DecoderUnavailable = error else {
                return XCTFail("Expected av1DecoderUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(try TranscodeService.inputDecoderArguments(videoCodec: "hevc",
            hasSoftwareAV1Decoder: false, hasHardwareAV1Decoder: false), [])
    }

    func testInputDecoderArgumentsPrecedeSourceInput() throws {
        let step = TranscodePlanner.plan(info: info(video: "av1"), intent: .airPlay, selectedAudioID: 2).steps.last!
        let args = try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step,
            selection: TrackSelection(audioID: 2), sourceHasAudio: true,
            inputArguments: ["-hwaccel", "videotoolbox"])
        let hwaccel = try XCTUnwrap(args.firstIndex(of: "-hwaccel"))
        let input = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertEqual(args[hwaccel + 1], "videotoolbox")
        XCTAssertLessThan(hwaccel, input)
        XCTAssertEqual(args[input + 1], "/in.mkv")
    }

    func testFFprobeHDRInfoTriggersAirPlayPreparationWithoutAVFoundationFlags() {
        // An HDR/DV MKV is not openable by AVFoundation, so formatFlags stays
        // empty and only FFprobe knows the stream is HDR. A locally prepared
        // copy must still be re-prepared before AirPlay playback.
        let item = MediaItem(fileURL: URL(fileURLWithPath: "/tmp/Movie.mkv"))
        item.mediaInfo = info(hdr: true, dolbyVision: true)
        item.transcodedURL = URL(fileURLWithPath: "/tmp/Movie_airplay.mp4")
        item.isAirPlayPrepared = false
        XCTAssertTrue(item.formatFlags.isEmpty)
        XCTAssertEqual(item.effectiveFormatFlags, [.dolbyVision, .hdr10])
        XCTAssertTrue(item.needsAirPlayTranscode)
        XCTAssertEqual(item.formatTag, "DV")

        item.isAirPlayPrepared = true
        XCTAssertFalse(item.needsAirPlayTranscode)
    }

    func testSDRInfoDoesNotTriggerAirPlayPreparation() {
        let item = MediaItem(fileURL: URL(fileURLWithPath: "/tmp/Movie.mkv"))
        item.mediaInfo = info(hdr: false)
        XCTAssertFalse(item.needsAirPlayTranscode)
        XCTAssertNil(item.formatTag)
    }

    func testHLGInfoMapsToHLGFlag() {
        let hlg = MediaInfo(formatName: "matroska,webm", duration: 10, videoCodec: "hevc",
            videoProfile: "Main 10", pixelFormat: "yuv420p10le", colorTransfer: "arib-std-b67",
            isDolbyVision: false, tracks: [])
        XCTAssertEqual(hlg.formatFlags, [.hlg])
    }

    func testOutputReservationKeepsMP4ExtensionAndAvoidsCollision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Movie with spaces.mkv")
        try Data("original".utf8).write(to: directory.appendingPathComponent("Movie with spaces_airplay.mp4"))
        let reservation = try OutputReservation.reserve(for: source)
        XCTAssertEqual(reservation.temporary.pathExtension, "mp4")
        XCTAssertEqual(reservation.destination.lastPathComponent, "Movie with spaces_airplay_1.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.destination.path))
    }

    func testOutputNamesUnicode() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("映画 🎬.mkv")
        XCTAssertTrue(try OutputReservation.reserve(for: source).destination.lastPathComponent.contains("airplay"))
    }

    func testExistingArtifactDiscoveryIncludesCollisionSuffixesOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("movie.mkv")
        for name in ["movie_airplay.mp4", "movie_airplay_1.mp4", "movie_other.mp4"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let names = Set(OutputReservation.existingArtifacts(for: source).map(\.lastPathComponent))
        XCTAssertEqual(names, ["movie_airplay.mp4", "movie_airplay_1.mp4"])
    }

    func testLocalCompatibleMP4UsesDirectPlayback() {
        XCTAssertTrue(TranscodePlanner.plan(info: info(format: "mp4", video: "h264"), intent: .local).steps.isEmpty)
    }

    func testSelectedSubtitleForcesMuxButKeepsCompatibleAudioCopy() {
        let plan = TranscodePlanner.plan(info: info(format: "mp4", video: "h264"), intent: .local,
                                         requiresSubtitleMuxing: true)
        XCTAssertFalse(plan.steps.isEmpty)
        XCTAssertEqual(plan.steps.first?.strategy, .remux)
        XCTAssertEqual(plan.steps.first?.audioArguments, ["-c:a", "copy"])
    }

    func testMatroskaUsesTypedFallbacks() {
        let plan = TranscodePlanner.plan(info: info(), intent: .local)
        XCTAssertEqual(plan.steps.first?.strategy, .remux)
        XCTAssertEqual(plan.steps.last?.strategy, .hardwareEncode)
    }

    func testDolbyVisionAirPlayStartsWithHDRRemux() {
        let plan = TranscodePlanner.plan(info: info(hdr: true, dolbyVision: true), intent: .airPlay)
        XCTAssertEqual(plan.steps.first?.strategy, .hdrRemux)
        XCTAssertEqual(plan.steps.first?.requiresHVC1, true)
        XCTAssertTrue(plan.reason.contains("Dolby Vision"))
    }

    func testUnsupportedVideoUsesAppleHardwareEncoding() {
        let steps = TranscodePlanner.plan(info: info(video: "av1", audio: "opus"), intent: .airPlay).steps
        XCTAssertEqual(steps.map(\.strategy), [.hardwareEncode])
        XCTAssertTrue(steps[0].videoArguments.contains("h264_videotoolbox"))
        XCTAssertNil(steps[0].requiredTransfer)
    }

    private func audioTrack(_ codec: String, channels: Int?) -> MediaTrack {
        MediaTrack(id: 2, kind: .audio, codec: codec, language: "eng", title: nil,
                   channels: channels, isDefault: true, isTextSubtitle: false)
    }

    func testCompatibleAudioIsCopiedOnlyWithoutProcessing() {
        for codec in ["aac", "ac3", "eac3", "AC3"] {
            XCTAssertEqual(AudioArguments.preferred(audioTrack(codec, channels: 6), mode: .standard,
                syncAdjustment: .zero, surroundEncoder: .eac3), ["-c:a", "copy"], codec)
        }
        XCTAssertFalse(AudioArguments.canCopy(audioTrack("eac3", channels: 6), mode: .lateNight, syncAdjustment: .zero))
        XCTAssertFalse(AudioArguments.canCopy(audioTrack("eac3", channels: 6), mode: .standard,
                                              syncAdjustment: SyncAdjustment(audioMilliseconds: 200)))
        XCTAssertTrue(AudioArguments.canCopy(audioTrack("eac3", channels: 6), mode: .standard,
                                             syncAdjustment: SyncAdjustment(subtitleMilliseconds: 200)))
        XCTAssertFalse(AudioArguments.canCopy(audioTrack("dts", channels: 6), mode: .standard, syncAdjustment: .zero))
    }

    func testSurroundAudioIsEncodedAsEAC3UpTo51() {
        XCTAssertEqual(AudioArguments.encode(audioTrack("truehd", channels: 8), mode: .standard, surroundEncoder: .eac3),
                       ["-c:a", "eac3", "-ac:a", "6", "-b:a", "640k"])
        XCTAssertEqual(AudioArguments.encode(audioTrack("dts", channels: 6), mode: .standard, surroundEncoder: .eac3),
                       ["-c:a", "eac3", "-ac:a", "6", "-b:a", "640k"])
        XCTAssertEqual(AudioArguments.encode(audioTrack("flac", channels: 4), mode: .standard, surroundEncoder: .eac3),
                       ["-c:a", "eac3", "-ac:a", "4", "-b:a", "448k"])
        XCTAssertEqual(AudioArguments.encode(audioTrack("dts", channels: 6), mode: .standard, surroundEncoder: .aac),
                       ["-c:a", "aac", "-ac:a", "6", "-b:a", "384k"])
    }

    func testStereoAndLateNightAudioStayStereoAAC() {
        XCTAssertEqual(AudioArguments.encode(audioTrack("opus", channels: 2), mode: .standard, surroundEncoder: .eac3),
                       AudioArguments.stereo)
        XCTAssertEqual(AudioArguments.encode(audioTrack("mp3", channels: nil), mode: .standard, surroundEncoder: .eac3),
                       AudioArguments.stereo)
        XCTAssertEqual(AudioArguments.encode(audioTrack("dts", channels: 6), mode: .lateNight, surroundEncoder: .eac3),
                       AudioArguments.stereo)
    }

    func testAirPlayPlanKeepsSurroundForDTSInMKV() {
        let source = MediaInfo(formatName: "matroska,webm", duration: 120, videoCodec: "h264",
            videoProfile: "High", pixelFormat: "yuv420p", colorTransfer: nil, isDolbyVision: false,
            tracks: [audioTrack("dts", channels: 6)])
        let steps = TranscodePlanner.plan(info: source, intent: .airPlay, selectedAudioID: 2).steps
        XCTAssertEqual(steps.map(\.strategy), [.audioTranscode, .hardwareEncode])
        for step in steps { XCTAssertEqual(step.audioArguments, ["-c:a", "eac3", "-ac:a", "6", "-b:a", "640k"]) }
        let aacOnly = TranscodePlanner.plan(info: source, intent: .airPlay, selectedAudioID: 2,
                                            surroundEncoder: .aac).steps
        XCTAssertEqual(aacOnly.first?.audioArguments, ["-c:a", "aac", "-ac:a", "6", "-b:a", "384k"])
    }

    func testAirPlayPlanCopiesEAC3AndFallsBackToEncodedAudio() {
        let source = MediaInfo(formatName: "matroska,webm", duration: 120, videoCodec: "mpeg2video",
            videoProfile: nil, pixelFormat: "yuv420p", colorTransfer: nil, isDolbyVision: false,
            tracks: [audioTrack("eac3", channels: 6)])
        let steps = TranscodePlanner.plan(info: source, intent: .airPlay, selectedAudioID: 2).steps
        XCTAssertEqual(steps.map(\.strategy), [.hardwareEncode, .hardwareEncode])
        XCTAssertEqual(steps[0].audioArguments, ["-c:a", "copy"])
        XCTAssertEqual(steps[1].audioArguments, ["-c:a", "eac3", "-ac:a", "6", "-b:a", "640k"])

        let h264 = MediaInfo(formatName: "matroska,webm", duration: 120, videoCodec: "h264",
            videoProfile: "High", pixelFormat: "yuv420p", colorTransfer: nil, isDolbyVision: false,
            tracks: [audioTrack("ac3", channels: 6)])
        let remux = TranscodePlanner.plan(info: h264, intent: .airPlay, selectedAudioID: 2).steps.first
        XCTAssertEqual(remux?.strategy, .remux)
        XCTAssertEqual(remux?.audioArguments, ["-c:a", "copy"])
    }

    func testHDRRemuxCopiesCompatibleSurround() {
        let source = MediaInfo(formatName: "matroska,webm", duration: 120, videoCodec: "hevc",
            videoProfile: "Main 10", pixelFormat: "yuv420p10le", colorTransfer: "smpte2084", isDolbyVision: true,
            tracks: [audioTrack("eac3", channels: 6)])
        let steps = TranscodePlanner.plan(info: source, intent: .airPlay, selectedAudioID: 2).steps
        XCTAssertEqual(steps.map(\.strategy), [.hdrRemux, .hardwareEncode, .hardwareEncode])
        XCTAssertEqual(steps[0].audioArguments, ["-c:a", "copy"])
        XCTAssertEqual(steps[2].audioArguments.first(where: { $0 == "eac3" }), "eac3")
    }

    private func video(_ codec: String, profile: String?, pixelFormat: String?, width: Int? = 1920,
                       height: Int? = 1080, frameRate: String? = "24000/1001", hdr: Bool = false) -> MediaInfo {
        MediaInfo(formatName: "mov,mp4,m4a,3gp,3g2,mj2", duration: 120, videoCodec: codec,
            videoProfile: profile, pixelFormat: pixelFormat, colorTransfer: hdr ? "arib-std-b67" : nil,
            isDolbyVision: false, tracks: [audioTrack("aac", channels: 2)],
            width: width, height: height, averageFrameRate: frameRate)
    }

    func testProbeMapsVideoDimensionsAndFrameRate() throws {
        // Verbatim FFprobe 9.0.2 fields from a generated 10-bit libx264 clip.
        let data = #"{"streams":[{"index":0,"codec_name":"h264","profile":"High 10","codec_type":"video","width":320,"height":180,"pix_fmt":"yuv420p10le","level":12,"r_frame_rate":"24/1","avg_frame_rate":"24/1"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.000000"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertEqual(mapped.width, 320)
        XCTAssertEqual(mapped.height, 180)
        XCTAssertEqual(mapped.frameRate, 24)
        XCTAssertEqual(AppleTVVideoCompatibility.issues(for: mapped),
                       [.profile("High 10"), .pixelFormat("yuv420p10le")])
        XCTAssertNil(video("h264", profile: nil, pixelFormat: nil, frameRate: "0/0").frameRate)
    }

    func testAppleTVRulesAcceptStreamableVideo() {
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("h264", profile: "High", pixelFormat: "yuv420p")))
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("h264", profile: "Constrained Baseline",
            pixelFormat: "yuvj420p", width: 1080, height: 1920, frameRate: "30/1")))
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("hevc", profile: "Main 10",
            pixelFormat: "yuv420p10le", width: 3840, height: 2160, frameRate: "60000/1001", hdr: true)))
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("hevc", profile: "Main",
            pixelFormat: "yuv420p", width: 4096, height: 2160, frameRate: "60/1")))
        // Variable-frame-rate 60 fps recordings often probe slightly above 60.
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("h264", profile: "High",
            pixelFormat: "yuv420p", frameRate: "301/5")))
        XCTAssertFalse(AppleTVVideoCompatibility.isCompatible(video("h264", profile: "High",
            pixelFormat: "yuv420p", frameRate: "64/1")))
        // Unrecognised profile names defer to the pixel format.
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("h264", profile: "Progressive High",
            pixelFormat: "yuv420p")))
        // Missing probe fields must not force a lossy re-encode.
        XCTAssertTrue(AppleTVVideoCompatibility.isCompatible(video("hevc", profile: nil, pixelFormat: nil,
            width: nil, height: nil, frameRate: nil)))
        XCTAssertTrue(AppleTVVideoCompatibility.issues(for: info(video: "h264", audio: nil)).isEmpty)
    }

    func testAppleTVRulesRejectVideoTheMacPlaysButAppleTVDoesNot() {
        typealias Rules = AppleTVVideoCompatibility
        XCTAssertEqual(Rules.issues(for: video("h264", profile: "High 4:2:2", pixelFormat: "yuv422p")),
                       [.profile("High 4:2:2"), .pixelFormat("yuv422p")])
        XCTAssertEqual(Rules.issues(for: video("h264", profile: "High 4:4:4 Predictive", pixelFormat: "yuv444p")).count, 2)
        XCTAssertEqual(Rules.issues(for: video("hevc", profile: "Rext", pixelFormat: "yuv422p10le")),
                       [.profile("Rext"), .pixelFormat("yuv422p10le")])
        XCTAssertEqual(Rules.issues(for: video("av1", profile: "Main", pixelFormat: "yuv420p")), [.codec("av1")])
        XCTAssertEqual(Rules.issues(for: video("hevc", profile: "Main", pixelFormat: "yuv420p",
            width: 7680, height: 4320)), [.resolution(width: 7680, height: 4320)])
        XCTAssertEqual(Rules.issues(for: video("h264", profile: "High", pixelFormat: "yuv420p",
            frameRate: "120/1")), [.frameRate(120)])
        XCTAssertEqual(Rules.reason(for: [.profile("High 10"), .frameRate(120)]),
                       "Apple TV cannot play the High 10 profile, 120 fps streamed over AirPlay.")
    }

    func testConformingArgumentsScaleAndHalveFrameRate() {
        let eightK = video("hevc", profile: "Main", pixelFormat: "yuv420p", width: 7680, height: 4320,
                           frameRate: "120000/1001")
        let limits = AppleTVVideoCompatibility.conformingArguments(for: eightK)
        XCTAssertEqual(limits.filters, ["scale=w=4096:h=2160:force_original_aspect_ratio=decrease:force_divisible_by=2"])
        XCTAssertEqual(limits.output, ["-r", "120000/2002"])
        let portrait = video("h264", profile: "High", pixelFormat: "yuv420p", width: 4320, height: 7680,
                             frameRate: "240/1")
        XCTAssertEqual(AppleTVVideoCompatibility.conformingArguments(for: portrait).filters,
                       ["scale=w=2160:h=4096:force_original_aspect_ratio=decrease:force_divisible_by=2"])
        XCTAssertEqual(AppleTVVideoCompatibility.conformingArguments(for: portrait).output, ["-r", "240/4"])
        let fine = AppleTVVideoCompatibility.conformingArguments(for: video("h264", profile: "High", pixelFormat: "yuv420p"))
        XCTAssertTrue(fine.filters.isEmpty)
        XCTAssertTrue(fine.output.isEmpty)
    }

    func testAirPlayPlanNeverCopiesVideoAppleTVCannotDecode() {
        let sources = [
            video("h264", profile: "High 10", pixelFormat: "yuv420p10le"),
            video("h264", profile: "High", pixelFormat: "yuv420p", frameRate: "120/1"),
            video("hevc", profile: "Rext", pixelFormat: "yuv422p10le"),
            video("hevc", profile: "Rext", pixelFormat: "yuv422p10le", hdr: true),
            video("hevc", profile: "Main 10", pixelFormat: "yuv420p10le", width: 7680, height: 4320, hdr: true),
        ]
        for source in sources {
            let plan = TranscodePlanner.plan(info: source, intent: .airPlay, selectedAudioID: 2)
            XCTAssertFalse(plan.steps.isEmpty)
            XCTAssertTrue(plan.reason.hasPrefix("Apple TV cannot play"), plan.reason)
            for step in plan.steps {
                XCTAssertFalse(step.videoArguments.contains("copy"), "\(step.strategy) copies video: \(step.videoArguments)")
                XCTAssertEqual(step.strategy, .hardwareEncode)
            }
        }
        let tenBit = TranscodePlanner.plan(info: sources[0], intent: .airPlay, selectedAudioID: 2).steps[0]
        XCTAssertEqual(tenBit.videoArguments, ["-vf", "format=yuv420p", "-c:v", "h264_videotoolbox", "-b:v", "7800k"])
        XCTAssertEqual(tenBit.audioArguments, ["-c:a", "copy"])
        let fast = TranscodePlanner.plan(info: sources[1], intent: .airPlay, selectedAudioID: 2).steps[0]
        XCTAssertEqual(Array(fast.videoArguments.prefix(4)), ["-vf", "format=yuv420p", "-r", "120/2"])
        let hlg422 = TranscodePlanner.plan(info: sources[3], intent: .airPlay, selectedAudioID: 2).steps[0]
        XCTAssertTrue(hlg422.videoArguments.contains("hevc_videotoolbox"))
        XCTAssertEqual(hlg422.requiredTransfer, "arib-std-b67")
        let eightK = TranscodePlanner.plan(info: sources[4], intent: .airPlay, selectedAudioID: 2).steps[0]
        XCTAssertEqual(eightK.videoArguments[1],
            "scale=w=4096:h=2160:force_original_aspect_ratio=decrease:force_divisible_by=2,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc")
    }

    func testLocalPlanStillCopiesVideoTheMacPlays() {
        let tenBit = video("h264", profile: "High 10", pixelFormat: "yuv420p10le")
        let steps = TranscodePlanner.plan(info: tenBit, intent: .local, selectedAudioID: 2,
                                          requiresSubtitleMuxing: true).steps
        XCTAssertEqual(steps.first?.strategy, .remux)
        XCTAssertEqual(steps.first?.videoArguments, ["-c:v", "copy"])
        let compatible = video("h264", profile: "High", pixelFormat: "yuv420p")
        XCTAssertEqual(TranscodePlanner.plan(info: compatible, intent: .airPlay, selectedAudioID: 2).steps.first?.strategy, .remux)
    }

    func testIncompatibleVideoTriggersAirPlayPreparationUntilAirPlayCopyExists() {
        // AVFoundation marks any HEVC source with audio as AirPlay-prepared,
        // including range-extension HEVC the Apple TV cannot decode.
        let item = MediaItem(fileURL: URL(fileURLWithPath: "/tmp/Camera.mov"))
        item.mediaInfo = video("hevc", profile: "Rext", pixelFormat: "yuv422p10le")
        item.isAirPlayPrepared = true
        XCTAssertTrue(item.needsAirPlayTranscode)

        // An unprobed local copy is judged by its source.
        let local = URL(fileURLWithPath: "/tmp/Camera_local.mp4")
        item.transcodedURL = local
        item.playbackIntent = .local
        XCTAssertTrue(item.needsAirPlayTranscode)
        // A local H.264 encode that probed compatible streams as it is.
        item.preparedCopyCompatibility = (local, true)
        XCTAssertFalse(item.needsAirPlayTranscode)
        item.preparedCopyCompatibility = (local, false)
        XCTAssertTrue(item.needsAirPlayTranscode)
        // A probe result for a different copy does not apply.
        item.preparedCopyCompatibility = (URL(fileURLWithPath: "/tmp/Other.mp4"), true)
        XCTAssertTrue(item.needsAirPlayTranscode)

        item.transcodedURL = URL(fileURLWithPath: "/tmp/Camera_airplay.mp4")
        item.playbackIntent = .airPlay
        XCTAssertFalse(item.needsAirPlayTranscode)

        let compatible = MediaItem(fileURL: URL(fileURLWithPath: "/tmp/Clip.mp4"))
        compatible.mediaInfo = video("h264", profile: "High", pixelFormat: "yuv420p")
        XCTAssertFalse(compatible.needsAirPlayTranscode)
    }

    private func hdrBitRate(width: Int?, height: Int?, frameRate: String?, source: Int? = nil,
                            intent: PlaybackIntent = .airPlay) -> Int {
        var info = video("vp9", profile: nil, pixelFormat: "yuv420p10le", width: width, height: height,
                         frameRate: frameRate, hdr: true)
        info.videoBitRate = source
        return VideoBitRate.kilobits(for: info, intent: intent, target: .hevcHDR)
    }

    func testHDRBitRateFollowsAppleLadderForResolution() {
        XCTAssertEqual(hdrBitRate(width: 1920, height: 1080, frameRate: "30/1"), 7_000)
        XCTAssertEqual(hdrBitRate(width: 3840, height: 2160, frameRate: "30000/1001"), 20_000)
        XCTAssertEqual(hdrBitRate(width: 2560, height: 1440, frameRate: "25/1"), 9_700)
        // 2.39:1 1080p sits between the 720p and 1080p rungs.
        XCTAssertEqual(hdrBitRate(width: 1920, height: 800, frameRate: "30/1"), 5_637)
        // Tiny frames scale down but keep a floor.
        XCTAssertEqual(hdrBitRate(width: 320, height: 180, frameRate: "30/1"), 500)
        // AirPlay scales 8K to 2160p; local playback keeps 8K.
        XCTAssertEqual(hdrBitRate(width: 7680, height: 4320, frameRate: "30/1"), 20_000)
        XCTAssertEqual(hdrBitRate(width: 7680, height: 4320, frameRate: "30/1", intent: .local), 80_000)
        // Missing size or rate must not lower quality.
        XCTAssertEqual(hdrBitRate(width: nil, height: nil, frameRate: nil), 20_000)
    }

    func testHDRBitRateAdjustsForFrameRateAndSourceRate() {
        XCTAssertEqual(hdrBitRate(width: 3840, height: 2160, frameRate: "24000/1001"), 16_000)
        XCTAssertEqual(hdrBitRate(width: 3840, height: 2160, frameRate: "60/1"), 30_000)
        XCTAssertEqual(hdrBitRate(width: 3840, height: 2160, frameRate: "60000/1001"), 29_980)
        // AirPlay halves 120 fps, so the rate follows the 60 fps output.
        XCTAssertEqual(hdrBitRate(width: 1920, height: 1080, frameRate: "120/1"), 10_500)
        // A low-rate source caps the encode at 125% of its own rate.
        XCTAssertEqual(hdrBitRate(width: 1920, height: 1080, frameRate: "30/1", source: 4_000_000), 5_000)
        XCTAssertEqual(hdrBitRate(width: 1920, height: 1080, frameRate: "30/1", source: 40_000_000), 7_000)
    }

    private func h264BitRate(_ codec: String = "mpeg2video", width: Int?, height: Int?, frameRate: String?,
                             source: Int? = nil) -> Int {
        var info = video(codec, profile: nil, pixelFormat: "yuv420p", width: width, height: height,
                         frameRate: frameRate)
        info.videoBitRate = source
        return VideoBitRate.kilobits(for: info, intent: .airPlay, target: .h264)
    }

    func testH264BitRateFollowsAppleLadder() {
        XCTAssertEqual(h264BitRate(width: 1920, height: 1080, frameRate: "30/1"), 7_800)
        XCTAssertEqual(h264BitRate(width: 1280, height: 720, frameRate: "25/1"), 4_500)
        XCTAssertEqual(h264BitRate(width: 960, height: 540, frameRate: "30/1"), 2_000)
        XCTAssertEqual(h264BitRate(width: 320, height: 180, frameRate: "30/1"), 500)
        // Apple's H.264 column stops at 1080p; 2160p scales by pixel count.
        XCTAssertEqual(h264BitRate(width: 3840, height: 2160, frameRate: "30/1"), 31_200)
        // The 24 fps reduction applies to HEVC only; 60 fps adds half.
        XCTAssertEqual(h264BitRate(width: 1920, height: 1080, frameRate: "24000/1001"), 7_800)
        XCTAssertEqual(h264BitRate(width: 1920, height: 1080, frameRate: "60/1"), 11_700)
    }

    func testH264BitRateCapDependsOnSourceCodecEfficiency() {
        // Re-encoding H.264 or older codecs allows 125% of the source rate.
        XCTAssertEqual(h264BitRate("h264", width: 1920, height: 1080, frameRate: "30/1", source: 4_000_000), 5_000)
        XCTAssertEqual(h264BitRate("mpeg2video", width: 1920, height: 1080, frameRate: "30/1", source: 4_000_000), 5_000)
        // HEVC, VP9, and AV1 need about twice the rate as H.264.
        XCTAssertEqual(h264BitRate("vp9", width: 1920, height: 1080, frameRate: "30/1", source: 3_000_000), 6_000)
        XCTAssertEqual(h264BitRate("av1", width: 1920, height: 1080, frameRate: "30/1", source: 5_000_000), 7_800)
        let plan = TranscodePlanner.plan(info: video("vp9", profile: nil, pixelFormat: "yuv420p",
            width: 1280, height: 720, frameRate: "30/1"), intent: .airPlay, selectedAudioID: 2)
        let step = plan.steps.last!
        XCTAssertEqual(step.videoArguments.suffix(4), ["-c:v", "h264_videotoolbox", "-b:v", "4500k"])
    }

    func testHDRBitRateUsesProbedSourceRates() throws {
        // Verbatim FFprobe 9.0.2 fields from a generated 4:2:2 HLG libx265 clip.
        let data = #"{"streams":[{"index":0,"codec_name":"hevc","profile":"Rext","codec_type":"video","width":1920,"height":1080,"pix_fmt":"yuv422p10le","color_transfer":"arib-std-b67","color_primaries":"bt2020","avg_frame_rate":"50/1","bit_rate":"6342024"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.000000","bit_rate":"6455536"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertEqual(mapped.videoBitRate, 6_342_024)
        XCTAssertEqual(mapped.containerBitRate, 6_455_536)
        // 50 fps raises 7,000 to 9,333; the 6.34 Mbit/s source caps it at 7,928.
        XCTAssertEqual(VideoBitRate.kilobits(for: mapped, intent: .airPlay, target: .hevcHDR), 7_928)
        let step = TranscodePlanner.plan(info: mapped, intent: .airPlay).steps[0]
        let rate = try XCTUnwrap(step.videoArguments.firstIndex(of: "-b:v"))
        XCTAssertEqual(step.videoArguments[rate + 1], "7928k")

        // Matroska streams have no bit_rate; mkvmerge writes a BPS tag, and
        // FFmpeg-muxed files only have the container rate.
        let mkv = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"vp9","tags":{"BPS-eng":"3000000"}}],"format":{"format_name":"matroska,webm","bit_rate":"3200000"}}"#.data(using: .utf8)!
        XCTAssertEqual(FFprobeService.mediaInfo(from: try FFprobeService.parse(mkv)).estimatedVideoBitRate, 3_000_000)
        let bare = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"vp9"}],"format":{"format_name":"matroska,webm","bit_rate":"3200000"}}"#.data(using: .utf8)!
        XCTAssertEqual(FFprobeService.mediaInfo(from: try FFprobeService.parse(bare)).estimatedVideoBitRate, 3_200_000)
    }

    func testNonHEVCHDRIsEncodedAsTaggedHEVCMain10() {
        for intent in PlaybackIntent.allCases {
            for (codec, transfer) in [("vp9", "smpte2084"), ("av1", "arib-std-b67")] {
                var source = info(video: codec, audio: "opus", hdr: true)
                source = MediaInfo(formatName: source.formatName, duration: source.duration,
                    videoCodec: codec, videoProfile: nil, pixelFormat: "yuv420p10le",
                    colorTransfer: transfer, isDolbyVision: false, tracks: source.tracks,
                    colorPrimaries: "bt2020", colorSpace: "bt2020nc")
                let steps = TranscodePlanner.plan(info: source, intent: intent, selectedAudioID: 2).steps
                XCTAssertEqual(steps.count, 1, "\(codec) \(intent): no 8-bit H.264 fallback")
                let step = steps[0]
                XCTAssertEqual(step.strategy, .hardwareEncode)
                XCTAssertTrue(step.requiresHVC1)
                XCTAssertEqual(step.requiredTransfer, transfer)
                XCTAssertTrue(step.videoArguments.contains("hevc_videotoolbox"))
                XCTAssertFalse(step.videoArguments.contains("h264_videotoolbox"))
                let filter = step.videoArguments[step.videoArguments.firstIndex(of: "-vf")! + 1]
                XCTAssertEqual(filter, "setparams=color_primaries=bt2020:color_trc=\(transfer):colorspace=bt2020nc")
                let profile = step.videoArguments.firstIndex(of: "-profile:v")!
                XCTAssertEqual(step.videoArguments[profile + 1], "main10")
            }
        }
    }

    func testHDRColorFilterDefaultsMissingPrimariesAndMatrixToBT2020() {
        let source = MediaInfo(formatName: "matroska,webm", duration: 1, videoCodec: "vp9",
            videoProfile: nil, pixelFormat: "yuv420p10le", colorTransfer: "smpte2084",
            isDolbyVision: false, tracks: [], colorPrimaries: "unknown", colorSpace: nil)
        XCTAssertEqual(HDRVideoArguments.colorFilter(for: source),
                       "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc")
        XCTAssertNil(HDRVideoArguments.colorFilter(for: info(video: "vp9", hdr: false)))
    }

    func testHEVCHDRAirPlayStepsRequireTransferAndTagTheEncode() {
        let steps = TranscodePlanner.plan(info: info(hdr: true), intent: .airPlay).steps
        // The 5.1 AAC source is copied first; the last encode re-encodes it.
        XCTAssertEqual(steps.map(\.strategy), [.hdrRemux, .hardwareEncode, .hardwareEncode])
        XCTAssertEqual(steps.map(\.requiredTransfer), ["smpte2084", "smpte2084", "smpte2084"])
        XCTAssertTrue(steps[1].videoArguments.contains("-vf"))
        XCTAssertEqual(steps[1].audioArguments, ["-c:a", "copy"])
        XCTAssertEqual(steps[2].audioArguments, ["-c:a", "eac3", "-ac:a", "6", "-b:a", "640k"])
    }

    func testTransferNamesMapToCoreMediaValues() {
        XCTAssertEqual(MediaArtifactValidator.coreMediaTransferFunction(forFFmpegName: "smpte2084"),
                       kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(MediaArtifactValidator.coreMediaTransferFunction(forFFmpegName: "arib-std-b67"),
                       kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertNil(MediaArtifactValidator.coreMediaTransferFunction(forFFmpegName: "bt709"))
    }

    func testValidatorRejectsOutputThatLostHDRTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sdr.mp4")
        try await writeGeneratedSDRMovie(to: url)

        let sdr = await MediaArtifactValidator.validate(url, sourceHadAudio: false)
        XCTAssertTrue(sdr.isValid, sdr.reason ?? "")
        let hdr = await MediaArtifactValidator.validate(url, sourceHadAudio: false, requiredTransfer: "smpte2084")
        XCTAssertFalse(hdr.isValid)
        XCTAssertEqual(hdr.reason, "Output lost the source's HDR transfer function.")
    }

    func testValidatorRejectsOutputWithoutDolbyVisionSampleEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plain.mp4")
        try await writeGeneratedSDRMovie(to: url)

        let result = await MediaArtifactValidator.validate(url, sourceHadAudio: false, requiresDolbyVision: true)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.reason, "Output lost its Dolby Vision dvh1 sample entry or configuration.")
        let flags = await VideoFormatProbe.inspect(AVURLAsset(url: url))
        XCTAssertTrue(flags.isEmpty)
    }

    /// Writes a 10-frame, 64×64 H.264 movie tagged BT.709 with AVAssetWriter.
    private func writeGeneratedSDRMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    func testExplicitAudioMappingUsesAbsoluteStreamIndex() throws {
        let args = try TranscodeService.streamArguments(
            selection: TrackSelection(audioID: 4, subtitleID: nil), sourceHasAudio: true)
        XCTAssertTrue(args.contains("0:4"))
        XCTAssertFalse(args.contains("0:a:0?"))
    }

    func testSelectedSubtitleIsMapped() throws {
        let selection = TrackSelection(audioID: 4, subtitleID: 7, subtitlePolicy: .includeSelected)
        let args = try TranscodeService.streamArguments(selection: selection, sourceHasAudio: true)
        XCTAssertTrue(args.contains("0:7"))
        XCTAssertFalse(args.contains("-sn"))
    }

    func testExternalSubtitleUsesSecondInputAndPreservesPathAsOneArgument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("movie with spaces \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("Movie.en.srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nCue\n".utf8).write(to: sidecar)
        let descriptor = try XCTUnwrap(ExternalSubtitleService.descriptor(for: sidecar))
        let step = TranscodePlanner.plan(info: info(), intent: .local).steps[1]
        let args = try TranscodeService.ffmpegArguments(input: directory.appendingPathComponent("Movie.mkv"),
            output: directory.appendingPathComponent("out.mp4"), step: step,
            selection: TrackSelection(audioID: 2, subtitle: .external(descriptor), subtitlePolicy: .includeSelected),
            sourceHasAudio: true)
        XCTAssertEqual(args[args.firstIndex(of: "-i")!.advanced(by: 1)], directory.appendingPathComponent("Movie.mkv").path)
        XCTAssertTrue(args.windows(ofCount: 2).contains { Array($0) == ["-map", "1:0"] })
        XCTAssertTrue(args.contains("mov_text"))
        XCTAssertTrue(args.contains(sidecar.path))
    }

    func testOmittedSubtitlesAddSn() throws {
        let args = try TranscodeService.streamArguments(
            selection: TrackSelection(audioID: 2, subtitleID: 7, subtitlePolicy: .omit), sourceHasAudio: true)
        XCTAssertTrue(args.contains("-sn"))
        XCTAssertFalse(args.contains("0:7"))
    }

    func testAudioSourceRequiresSelection() {
        XCTAssertThrowsError(try TranscodeService.streamArguments(
            selection: TrackSelection(audioID: nil, subtitleID: nil), sourceHasAudio: true))
    }

    func testSilentSourceDoesNotRequireAudioSelection() throws {
        XCTAssertNoThrow(try TranscodeService.streamArguments(
            selection: TrackSelection(audioID: nil, subtitleID: nil), sourceHasAudio: false))
    }

    func testFFmpegArgumentsApplySelectedTracksAndCodecPlan() throws {
        let step = TranscodePlanner.plan(info: info(), intent: .local).steps[1]
        let args = try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step,
            selection: TrackSelection(audioID: 2, subtitleID: nil), sourceHasAudio: true)
        XCTAssertTrue(args.windows(ofCount: 2).contains { Array($0) == ["-map", "0:2"] })
        // The fixture's audio is 6-channel, so it is converted to E-AC3 5.1.
        XCTAssertTrue(args.windows(ofCount: 2).contains { Array($0) == ["-c:a", "eac3"] })
        XCTAssertTrue(args.windows(ofCount: 2).contains { Array($0) == ["-ac:a", "6"] })
        XCTAssertEqual(args.last, "/out.mp4")
    }

    func testHEVCRemuxUsesHVC1SampleEntry() {
        let step = TranscodePlanner.plan(info: info(), intent: .local).steps[0]
        XCTAssertEqual(step.strategy, .remux)
        XCTAssertTrue(step.videoArguments.windows(ofCount: 2).contains { Array($0) == ["-tag:v", "hvc1"] })
    }

    func testProgressParserSupportsMicroseconds() {
        XCTAssertEqual(TranscodeService.parseOutTime("out_time_us=2500000"), 2.5)
        XCTAssertEqual(TranscodeService.parseOutTime("out_time=01:02:03.5"), 3723.5)
    }

    func testProcessCancellationWaitsForTermination() async {
        let task = Task {
            try await TranscodeService.runProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10"], duration: nil, progress: { _ in })
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled process unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: the continuation resumes only after Process terminates.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testProbeJSONParsingAndMediaMapping() throws {
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","profile":"Main 10","pix_fmt":"yuv420p10le","color_transfer":"smpte2084","side_data_list":[{"side_data_type":"DOVI configuration record"}],"disposition":{"default":1}},{"index":3,"codec_type":"audio","codec_name":"eac3","channels":6,"tags":{"language":"eng","title":"English"},"disposition":{"default":1}}],"format":{"format_name":"matroska,webm","duration":"42.5"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertEqual(mapped.duration, 42.5)
        XCTAssertEqual(mapped.audioTracks.first?.id, 3)
        XCTAssertTrue(mapped.isHDR)
        XCTAssertTrue(mapped.isDolbyVision)
    }

    // The side-data fixtures below are verbatim FFprobe 9.0.2 JSON from tiny
    // clips generated with the lavfi testsrc2 source (no user media). FFprobe
    // emits numeric values here, which previously failed the entire decode.

    func testProbeParsesNumericRotationSideData() throws {
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","profile":"Main 10","pix_fmt":"yuv420p10le","side_data_list":[{"side_data_type":"Display Matrix","displaymatrix":"\n00000000:            0      -65536           0\n00000001:        65536           0           0\n00000002:            0           0  1073741824\n","rotation":90}],"disposition":{"default":1,"forced":0}}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.000000"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertEqual(mapped.rotation, 90)
        XCTAssertFalse(mapped.isDolbyVision)
        XCTAssertEqual(mapped.videoCodec, "hevc")
    }

    func testProbeParsesNumericHDRLightLevelSideData() throws {
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","profile":"Main 10","pix_fmt":"yuv420p10le","color_transfer":"smpte2084","side_data_list":[{"side_data_type":"Mastering display metadata","red_x":"34000/50000","red_y":"16000/50000","green_x":"13250/50000","green_y":"34500/50000","blue_x":"7500/50000","blue_y":"3000/50000","white_point_x":"15635/50000","white_point_y":"16450/50000","min_luminance":"1/10000","max_luminance":"10000000/10000"},{"side_data_type":"Content light level metadata","max_content":1000,"max_average":400}],"disposition":{"default":1,"forced":0}}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1.000000"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertTrue(mapped.isHDR)
        XCTAssertFalse(mapped.isDolbyVision)
        XCTAssertNil(mapped.rotation)
    }

    func testProbeParsesDolbyVisionConfigurationProfile() throws {
        // Field names and types match ffprobe.c print_int/print_str output
        // for AV_PKT_DATA_DOVI_CONF.
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","profile":"Main 10","pix_fmt":"yuv420p10le","color_transfer":"smpte2084","side_data_list":[{"side_data_type":"DOVI configuration record","dv_version_major":1,"dv_version_minor":0,"dv_profile":5,"dv_level":6,"rpu_present_flag":1,"el_present_flag":0,"bl_present_flag":1,"dv_bl_signal_compatibility_id":0,"dv_md_compression":"none"}],"disposition":{"default":1}}],"format":{"format_name":"matroska,webm","duration":"10.0"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertTrue(mapped.isDolbyVision)
        XCTAssertEqual(mapped.dolbyVisionProfile, 5)
        XCTAssertEqual(mapped.dolbyVisionCompatibilityID, 0)
    }

    func testProbeParsesDualLayerDolbyVisionProfile7() throws {
        // Field names and types match ffprobe.c output for AV_PKT_DATA_DOVI_CONF;
        // values are those of a UHD Blu-ray profile 7 stream (BL + EL + RPU).
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","profile":"Main 10","pix_fmt":"yuv420p10le","color_transfer":"smpte2084","side_data_list":[{"side_data_type":"DOVI configuration record","dv_version_major":1,"dv_version_minor":0,"dv_profile":7,"dv_level":6,"rpu_present_flag":1,"el_present_flag":1,"bl_present_flag":1,"dv_bl_signal_compatibility_id":6,"dv_md_compression":"none"}],"disposition":{"default":1}}],"format":{"format_name":"matroska,webm","duration":"10.0"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertEqual(mapped.dolbyVisionProfile, 7)
        XCTAssertEqual(mapped.dolbyVisionCompatibilityID, 6)
        XCTAssertEqual(mapped.dolbyVisionHasEnhancementLayer, true)
        XCTAssertTrue(mapped.isDualLayerDolbyVision)
    }

    func testDualLayerDolbyVisionRemuxStripsEnhancementLayerAndRPU() {
        var profile7 = info(hdr: true, dolbyVision: true)
        profile7.dolbyVisionProfile = 7
        profile7.dolbyVisionHasEnhancementLayer = true
        let plan = TranscodePlanner.plan(info: profile7, intent: .airPlay, selectedAudioID: 2)
        XCTAssertEqual(plan.reason, "Dual-layer Dolby Vision (profile 7) plays on Apple TV only as its HDR10 base layer.")
        let remux = plan.steps[0]
        XCTAssertEqual(remux.strategy, .hdrRemux)
        XCTAssertEqual(remux.videoArguments, ["-c:v", "copy", "-bsf:v", "filter_units=remove_types=62|63", "-tag:v", "hvc1"])
        XCTAssertTrue(remux.reason.contains("enhancement layer"))
        XCTAssertEqual(remux.requiredTransfer, "smpte2084")

        // A profile 7 record without el_present_flag is still dual-layer.
        var profileOnly = info(hdr: true, dolbyVision: true)
        profileOnly.dolbyVisionProfile = 7
        XCTAssertTrue(profileOnly.isDualLayerDolbyVision)

        var profile8 = info(hdr: true, dolbyVision: true)
        profile8.dolbyVisionProfile = 8
        profile8.dolbyVisionHasEnhancementLayer = false
        XCTAssertFalse(profile8.isDualLayerDolbyVision)
        let single = TranscodePlanner.plan(info: profile8, intent: .airPlay, selectedAudioID: 2)
        XCTAssertEqual(single.reason, "Dolby Vision needs an Apple TV compatible HDR10 fallback.")
        XCTAssertEqual(single.steps[0].videoArguments, remux.videoArguments)
        XCTAssertFalse(info(hdr: true).isDualLayerDolbyVision)
    }

    private func profile5(format: String = "matroska,webm") -> MediaInfo {
        var source = info(format: format, hdr: true, dolbyVision: true)
        source.dolbyVisionProfile = 5
        source.dolbyVisionCompatibilityID = 0
        return source
    }

    func testDolbyVisionProfile5IsKeptAsDolbyVisionWithoutEncodeFallback() {
        for intent in [PlaybackIntent.airPlay, .local] {
            let plan = TranscodePlanner.plan(info: profile5(), intent: intent, selectedAudioID: 2)
            XCTAssertEqual(plan.reason, "Dolby Vision profile 5 has no HDR10 base layer, so it is kept as Dolby Vision in a dvh1 MP4.")
            // Copy surround first, then retry with encoded audio; never re-encode video.
            XCTAssertEqual(plan.steps.map(\.strategy), [.dolbyVisionRemux, .dolbyVisionRemux])
            for step in plan.steps {
                XCTAssertEqual(step.videoArguments, ["-c:v", "copy", "-tag:v", "dvh1", "-strict", "unofficial"])
                XCTAssertTrue(step.requiresDolbyVision)
                XCTAssertFalse(step.requiresHVC1)
                XCTAssertFalse(step.videoArguments.contains("filter_units=remove_types=62|63"))
            }
            XCTAssertEqual(plan.steps[0].audioArguments, ["-c:a", "copy"])
            XCTAssertEqual(plan.steps[1].audioArguments, ["-c:a", "eac3", "-ac:a", "6", "-b:a", "640k"])
        }
        // Late Night still keeps the video as Dolby Vision.
        let lateNight = TranscodePlanner.plan(info: profile5(), intent: .airPlay, selectedAudioID: 2,
                                              audioProcessingMode: .lateNight)
        XCTAssertEqual(lateNight.steps.map(\.strategy), [.dolbyVisionRemux])
        XCTAssertEqual(lateNight.steps[0].audioArguments, AudioArguments.stereo)

        // Profile 8 and unknown profiles keep the HDR10 base-layer remux.
        var profile8 = info(hdr: true, dolbyVision: true)
        profile8.dolbyVisionProfile = 8
        XCTAssertFalse(profile8.isDolbyVisionProfile5)
        XCTAssertEqual(TranscodePlanner.plan(info: profile8, intent: .airPlay).steps.first?.strategy, .hdrRemux)
        XCTAssertEqual(TranscodePlanner.plan(info: info(hdr: true, dolbyVision: true), intent: .airPlay).steps.first?.strategy, .hdrRemux)
    }

    func testDolbyVisionPassthroughArgumentsKeepStrictForMuxerAndSubtitles() throws {
        let step = TranscodePlanner.plan(info: profile5(), intent: .airPlay, selectedAudioID: 2).steps[1]
        var selection = TrackSelection(audioID: 2)
        selection.subtitle = .embedded(streamID: 3)
        selection.subtitlePolicy = .includeSelected
        let args = try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step, selection: selection, sourceHasAudio: true)
        let strict = try XCTUnwrap(args.firstIndex(of: "-strict"))
        XCTAssertEqual(args[strict + 1], "unofficial")
        XCTAssertGreaterThan(strict, try XCTUnwrap(args.firstIndex(of: "-i")))
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-tag:v")) + 1], "dvh1")
        XCTAssertTrue(args.contains("mov_text"))
        XCTAssertEqual(args.last, "/out.mp4")
    }

    func testCachedCopyMustMatchDolbyVisionRequirement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let output = directory.appendingPathComponent("source_airplay.mp4")
        try Data("source".utf8).write(to: source)
        try Data("output".utf8).write(to: output)
        // A copy made before passthrough existed has no Dolby Vision requirement.
        try MediaArtifactValidator.writeManifest(source: source, artifact: output, sourceHadAudio: true,
            selectedAudioID: nil, expectedDuration: nil, requiresHVC1: true)
        let stale = await MediaArtifactValidator.validateCached(output, source: source, expectedDolbyVision: true)
        XCTAssertEqual(stale.reason, "No current artifact manifest")

        try MediaArtifactValidator.writeManifest(source: source, artifact: output, sourceHadAudio: true,
            selectedAudioID: nil, expectedDuration: nil, requiresHVC1: false, requiresDolbyVision: true)
        let manifest = try JSONDecoder().decode(MediaArtifactManifest.self,
            from: Data(contentsOf: MediaArtifactValidator.manifestURL(for: output)))
        XCTAssertEqual(manifest.requiresDolbyVision, true)
        // The manifest now matches, so validation reaches the (unplayable) file itself.
        let current = await MediaArtifactValidator.validateCached(output, source: source, expectedDolbyVision: true)
        XCTAssertNotEqual(current.reason, "No current artifact manifest")
        let mismatch = await MediaArtifactValidator.validateCached(output, source: source)
        XCTAssertEqual(mismatch.reason, "No current artifact manifest")
    }

    func testProbeToleratesUnexpectedSideDataFieldTypes() throws {
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"h264","side_data_list":[{"side_data_type":7,"rotation":"ninety","dv_profile":"eight"}]}],"format":{"format_name":"mp4","duration":"1.0"}}"#.data(using: .utf8)!
        let mapped = FFprobeService.mediaInfo(from: try FFprobeService.parse(data))
        XCTAssertEqual(mapped.videoCodec, "h264")
        XCTAssertNil(mapped.rotation)
        XCTAssertNil(mapped.dolbyVisionProfile)
    }

    func testProbeProcessDrainsLargeStderrWithoutHanging() async {
        do {
            _ = try await FFprobeService.runProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/usr/bin/yes diagnostic | /usr/bin/head -c 70000 >&2; printf '{}'"])
            XCTFail("Oversized diagnostics unexpectedly succeeded")
        } catch FFprobeError.outputTooLarge {
            // Expected: stderr is drained concurrently and bounded.
        } catch {
            XCTFail("Expected outputTooLarge, got \(error)")
        }
    }

    func testProbeProcessCancellationTerminatesChild() async {
        let task = Task {
            try await FFprobeService.runProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10"])
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled probe unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testGeneratedMediaPreparationAndCacheValidation() async throws {
        guard let installation = FFmpegLocator.locate() else {
            throw XCTSkip("FFmpeg integration test requires separately installed ffmpeg and ffprobe")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("generated.mkv")

        _ = try await FFprobeService.runProcess(executable: installation.ffmpeg, arguments: [
            "-y", "-f", "lavfi", "-i", "color=c=blue:s=320x180:d=1",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-shortest",
            "-c:v", "mpeg4", "-c:a", "aac", source.path
        ], timeout: 60)

        let info = try await FFprobeService.probe(source, using: installation)
        let selection = FFprobeService.defaultSelection(from: info)
        let artifact = try await TranscodeService.prepare(input: source, info: info,
            selection: selection, intent: .local, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))

        let validation = await MediaArtifactValidator.validateCached(artifact.url, source: source,
            expectedSelection: selection, expectedIntent: .local)
        XCTAssertTrue(validation.isValid, validation.reason ?? "Generated artifact was rejected")
        XCTAssertTrue(validation.hasVideo)
        XCTAssertTrue(validation.hasAudio)
    }

    func testPreferredAudioUsesDefaultInPreferredLanguageFirst() {
        let french = stream(index: 1, language: "fra", isDefault: true)
        let english = stream(index: 2, language: "eng", isDefault: true)
        XCTAssertEqual(FFprobeService.preferredAudio(from: [french, english], preferredLanguage: "eng")?.index, 2)
    }

    func testPreferredAudioFallsBackToDefault() {
        XCTAssertEqual(FFprobeService.preferredAudio(from: [stream(index: 1, language: "fra", isDefault: true)],
            preferredLanguage: "eng")?.index, 1)
    }

    func testDefaultSelectionUsesAbsoluteTrackID() {
        XCTAssertEqual(FFprobeService.defaultSelection(from: info()).audioID, 2)
    }

    func testManifestPersistsSourceAudioExpectationAndSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let output = directory.appendingPathComponent("output.mp4")
        try Data("source".utf8).write(to: source)
        try Data("output".utf8).write(to: output)
        try MediaArtifactValidator.writeManifest(source: source, artifact: output, sourceHadAudio: true,
            selectedAudioID: 5, expectedDuration: 10, requiresHVC1: true)
        let manifest = try JSONDecoder().decode(MediaArtifactManifest.self,
            from: Data(contentsOf: MediaArtifactValidator.manifestURL(for: output)))
        XCTAssertTrue(manifest.sourceHadAudio)
        XCTAssertEqual(manifest.selectedAudioID, 5)
        XCTAssertTrue(manifest.requiresHVC1)
        XCTAssertEqual(manifest.playbackIntent, .local)
        XCTAssertNil(manifest.appleTVRulesVersion)

        try MediaArtifactValidator.writeManifest(source: source, artifact: output, sourceHadAudio: true,
            selectedAudioID: 5, expectedDuration: 10, requiresHVC1: true, playbackIntent: .airPlay)
        let airPlay = try JSONDecoder().decode(MediaArtifactManifest.self,
            from: Data(contentsOf: MediaArtifactValidator.manifestURL(for: output)))
        XCTAssertEqual(airPlay.appleTVRulesVersion, AppleTVVideoCompatibility.rulesVersion)
    }

    func testManifestWriteFailsWhenSourceMissing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try MediaArtifactValidator.writeManifest(source: missing, artifact: missing,
            sourceHadAudio: false, selectedAudioID: nil, expectedDuration: nil, requiresHVC1: false))
    }

    func testConfiguredFFmpegDirectoryTakesPriority() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["ffmpeg", "ffprobe"] {
            let url = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let suite = "AirPlayDropTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(directory.path, forKey: FFmpegLocator.configuredDirectoryKey)
        XCTAssertEqual(FFmpegLocator.locate(defaults: defaults, environment: [:])?.ffmpeg.deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL)
    }

    func testBundledFFmpegIsUsedWithoutExternalInstallation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["ffmpeg", "ffprobe"] {
            let url = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let suite = "AirPlayDropTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let installation = FFmpegLocator.locate(defaults: defaults, environment: [:], bundledDirectory: directory)
        XCTAssertEqual(installation?.ffmpeg.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
    }

    func testJobRegistryRejectsStaleCompletion() {
        var registry = JobTokenRegistry()
        let itemID = UUID()
        let old = registry.begin(itemID: itemID)
        let current = registry.begin(itemID: itemID)
        XCTAssertFalse(registry.isCurrent(old, itemID: itemID))
        XCTAssertTrue(registry.isCurrent(current, itemID: itemID))
    }

    func testJobRegistryInvalidationRejectsCompletion() {
        var registry = JobTokenRegistry()
        let itemID = UUID()
        let token = registry.begin(itemID: itemID)
        registry.invalidate(itemID: itemID)
        XCTAssertFalse(registry.isCurrent(token, itemID: itemID))
    }

    func testPlaybackPreferencesNormalizeAndRoundTrip() throws {
        let preferences = PlaybackPreferences(audioLanguages: [" ENG ", "en", "sr-Latn"],
                                              subtitleLanguages: ["SR", "", "sr"],
                                              subtitleMode: .preferred)
        XCTAssertEqual(preferences.preferredAudioLanguages, ["en", "sr-latn"])
        XCTAssertEqual(preferences.preferredSubtitleLanguages, ["sr"])
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackPreferences.self, from: data), preferences)
    }

    func testPlaybackPreferencesCorruptDataFallsBack() {
        let suite = "AirPlayDropTests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: PlaybackPreferencesStore.defaultsKey)
        XCTAssertEqual(PlaybackPreferencesStore(defaults: defaults).preferences, .systemDefault)
    }

    func testPreferredSelectionMatchesRegionalLanguagesAndForcedSubtitles() {
        let tracks = [
            MediaTrack(id: 0, kind: .video, codec: "h264", language: nil, title: nil,
                       channels: nil, isDefault: true, isTextSubtitle: false),
            MediaTrack(id: 1, kind: .audio, codec: "aac", language: "en-US", title: nil,
                       channels: 2, isDefault: false, isTextSubtitle: false),
            MediaTrack(id: 2, kind: .audio, codec: "aac", language: "sr", title: nil,
                       channels: 2, isDefault: true, isTextSubtitle: false),
            MediaTrack(id: 3, kind: .subtitle, codec: "hdmv_pgs_subtitle", language: "en",
                       title: nil, channels: nil, isDefault: true, isTextSubtitle: false),
            MediaTrack(id: 4, kind: .subtitle, codec: "subrip", language: "en-US", title: nil,
                       channels: nil, isDefault: false, isTextSubtitle: true, isForced: true)
        ]
        let info = MediaInfo(formatName: "matroska", duration: 120, videoCodec: "h264",
                             videoProfile: nil, pixelFormat: nil, colorTransfer: nil,
                             isDolbyVision: false, tracks: tracks)
        let selection = FFprobeService.defaultSelection(from: info,
            preferences: PlaybackPreferences(audioLanguages: ["en"], subtitleLanguages: ["en"], subtitleMode: .forcedPreferred))
        XCTAssertEqual(selection.audioID, 1)
        XCTAssertEqual(selection.subtitleID, 4)
    }

    func testPreferredSelectionCanonicalizesISO639TwoAndThreeLetterCodes() {
        let tracks = [
            MediaTrack(id: 0, kind: .video, codec: "h264", language: nil, title: nil,
                       channels: nil, isDefault: true, isTextSubtitle: false),
            MediaTrack(id: 1, kind: .audio, codec: "aac", language: "srp", title: nil,
                       channels: 2, isDefault: true, isTextSubtitle: false),
            MediaTrack(id: 2, kind: .audio, codec: "aac", language: "eng", title: nil,
                       channels: 2, isDefault: false, isTextSubtitle: false)
        ]
        let media = MediaInfo(formatName: "matroska", duration: 120, videoCodec: "h264",
                              videoProfile: nil, pixelFormat: nil, colorTransfer: nil,
                              isDolbyVision: false, tracks: tracks)
        let selection = FFprobeService.defaultSelection(from: media,
            preferences: PlaybackPreferences(audioLanguages: ["en"], subtitleLanguages: []))
        XCTAssertEqual(selection.audioID, 2)
    }

    func testExternalSubtitleDiscoveryIsLocalAndDeterministic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Movie.mkv")
        try Data("video".utf8).write(to: movie)
        for name in ["Movie.srt", "Movie.en.srt", "Movie.SR.VTT", "Movie.jpg", "Other.srt"] {
            try Data("1".utf8).write(to: directory.appendingPathComponent(name))
        }
        let descriptors = ExternalSubtitleService.discover(for: movie,
            preferences: PlaybackPreferences(audioLanguages: [], subtitleLanguages: ["sr"], subtitleMode: .preferred))
        XCTAssertEqual(descriptors.map(\.displayName), ["Movie.srt", "Movie.SR.VTT", "Movie.en.srt"])
        XCTAssertEqual(descriptors[1].language, "sr")
    }

    func testPlaybackHistoryEligibilityAndFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("movie.mkv")
        try Data("one".utf8).write(to: source)
        let suite = "AirPlayDropTests.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackHistoryStore(defaults: defaults)
        XCTAssertTrue(PlaybackHistoryStore.isEligible(position: 30, duration: 120))
        XCTAssertFalse(PlaybackHistoryStore.isEligible(position: 29, duration: 120))
        XCTAssertFalse(PlaybackHistoryStore.isEligible(position: 30, duration: 89))
        store.save(sourceURL: source, position: 30, duration: 120, at: Date(timeIntervalSince1970: 1))
        XCTAssertNotNil(store.entry(for: source))
        try Data("replacement".utf8).write(to: source)
        XCTAssertNil(store.entry(for: source))
    }

    func testSyncAdjustmentClampsAndZeroPreservesArguments() throws {
        XCTAssertEqual(SyncAdjustment(audioMilliseconds: 50_000, subtitleMilliseconds: -50_000),
                       SyncAdjustment(audioMilliseconds: 10_000, subtitleMilliseconds: -10_000))
        let step = TranscodePlanner.plan(info: info(), intent: .local).steps[1]
        let selection = TrackSelection(audioID: 2)
        let standard = try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step, selection: selection, sourceHasAudio: true)
        let noOp = try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step, selection: selection,
            sourceHasAudio: true, syncAdjustment: .zero)
        XCTAssertEqual(standard, noOp)
        XCTAssertTrue(try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step, selection: selection,
            sourceHasAudio: true, syncAdjustment: SyncAdjustment(audioMilliseconds: 750)).contains("adelay=750:all=1") )
        XCTAssertTrue(try TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mkv"),
            output: URL(fileURLWithPath: "/out.mp4"), step: step, selection: selection,
            sourceHasAudio: true, syncAdjustment: SyncAdjustment(audioMilliseconds: 750),
            mediaDuration: 120).contains("adelay=750:all=1,atrim=end=120.000"))
    }

    func testLateNightForcesAudioTranscodeAndThumbnailsQuantize() {
        let plan = TranscodePlanner.plan(info: info(format: "mp4", video: "h264"), intent: .local,
                                         audioProcessingMode: .lateNight)
        XCTAssertEqual(plan.steps.first?.strategy, .audioTranscode)
        let arguments = try? TranscodeService.ffmpegArguments(input: URL(fileURLWithPath: "/in.mp4"),
            output: URL(fileURLWithPath: "/out.mp4"), step: plan.steps[0],
            selection: TrackSelection(audioID: 2), sourceHasAudio: true)
        XCTAssertTrue(arguments?.contains(AudioProcessingPreset.lateNightFilter) == true)
        XCTAssertEqual(ThumbnailProvider.quantizedBucket(1.99), 0)
        XCTAssertEqual(ThumbnailProvider.quantizedBucket(2.0), 1)
        XCTAssertNil(ThumbnailProvider.quantizedBucket(-1))
    }

    func testThumbnailProviderCachesAndBoundsEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("preview.mp4")
        try Data("fixture".utf8).write(to: source)
        let generator = TestThumbnailGenerator()
        let provider = ThumbnailProvider { _ in generator }
        let first = await provider.image(for: source, at: 0)
        let second = await provider.image(for: source, at: 1.9)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(generator.count, 1)
        for index in 1...31 {
            _ = await provider.image(for: source, at: Double(index * 2))
        }
        let entryCount = await provider.cachedEntryCount()
        XCTAssertEqual(entryCount, 30)
    }

    func testTrackDisplayNameIncludesLanguageCodecAndChannels() {
        let track = MediaTrack(id: 2, kind: .audio, codec: "eac3", language: "eng", title: nil,
            channels: 6, isDefault: true, isTextSubtitle: false)
        XCTAssertEqual(track.displayName, "ENG — EAC3 · 6 ch")
    }

    func testStateEqualityAndTerminalStatus() {
        XCTAssertNotEqual(MediaItemState.transcoding(0.1), .transcoding(0.2))
        XCTAssertTrue(MediaItemState.ready.isTerminal)
        XCTAssertFalse(MediaItemState.transcoding(0.4).isTerminal)
    }

    private func stream(index: Int, language: String, isDefault: Bool) -> FFprobeStream {
        FFprobeStream(index: index, codec_type: "audio", codec_name: "aac", codec_long_name: nil,
            channels: 2, channel_layout: "stereo", tags: ["language": language],
            disposition: ["default": isDefault ? 1 : 0], profile: nil, pix_fmt: nil,
            color_transfer: nil, side_data_list: nil)
    }
}

private extension Array {
    func windows(ofCount count: Int) -> [ArraySlice<Element>] {
        guard count > 0, count <= self.count else { return [] }
        return indices.dropLast(count - 1).map { self[$0..<(index($0, offsetBy: count))] }
    }
}

private final class TestThumbnailGenerator: ThumbnailImageGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func image(at time: CMTime, maximumSize: CGSize) throws -> CGImage {
        lock.lock(); calls += 1; lock.unlock()
        let provider = CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
