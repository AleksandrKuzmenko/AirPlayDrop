import XCTest
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
