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
        return MediaInfo(formatName: format, duration: 120, videoCodec: video, videoProfile: "Main 10",
            pixelFormat: "yuv420p10le", colorTransfer: hdr ? "smpte2084" : nil,
            isDolbyVision: dolbyVision, tracks: tracks)
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
        XCTAssertEqual(plan.steps.last?.strategy, .softwareEncode)
    }

    func testDolbyVisionAirPlayStartsWithHDRRemux() {
        let plan = TranscodePlanner.plan(info: info(hdr: true, dolbyVision: true), intent: .airPlay)
        XCTAssertEqual(plan.steps.first?.strategy, .hdrRemux)
        XCTAssertEqual(plan.steps.first?.requiresHVC1, true)
        XCTAssertTrue(plan.reason.contains("Dolby Vision"))
    }

    func testUnsupportedVideoIncludesHardwareAndSoftwareFallbacks() {
        let strategies = TranscodePlanner.plan(info: info(video: "av1", audio: "opus"), intent: .airPlay).steps.map(\.strategy)
        XCTAssertEqual(strategies, [.hardwareEncode, .softwareEncode])
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
        XCTAssertTrue(args.contains("aac"))
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
