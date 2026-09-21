import XCTest
@testable import AirPlayDrop

final class AirPlayDropTests: XCTestCase {
    func testOutputReservationKeepsMP4ExtensionAndAvoidsCollision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Movie with spaces.mkv")
        try Data("original".utf8).write(to: directory.appendingPathComponent("Movie with spaces_airplay.mp4"))
        let reservation = try OutputReservation.reserve(for: source)
        XCTAssertEqual(reservation.temporary.pathExtension, "mp4")
        XCTAssertNotEqual(reservation.destination.lastPathComponent, "Movie with spaces_airplay.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.destination.path))
    }

    func testPlannerChoosesHDRRemuxForHEVC() {
        let plan = TranscodePlanner.plan(videoCodec: "hevc", audioCodec: "eac3", isHDR: true, profile: .appleTV4KHDR)
        XCTAssertEqual(plan.strategy, .hdrRemux)
    }

    func testStateEqualityAndProgress() {
        XCTAssertEqual(MediaItemState.ready, .ready)
        XCTAssertNotEqual(MediaItemState.transcoding(0.1), .transcoding(0.2))
        XCTAssertEqual(MediaItemState.failed("x").errorDescription, "x")
    }

    func testPlannerCompatibilityRemux() { XCTAssertEqual(TranscodePlanner.plan(videoCodec: "h264", audioCodec: "aac", isHDR: false, profile: .maximumCompatibilitySDR).strategy, .remux) }
    func testPlannerSoftwareFallback() { XCTAssertEqual(TranscodePlanner.plan(videoCodec: "vp9", audioCodec: "opus", isHDR: false, profile: .maximumCompatibilitySDR).strategy, .softwareEncode) }
    func testPlannerHDRFallback() { XCTAssertEqual(TranscodePlanner.plan(videoCodec: "av1", audioCodec: "aac", isHDR: true, profile: .appleTV4KHDR).strategy, .hardwareEncode) }
    func testPlannerDirectPlayback() { XCTAssertEqual(TranscodePlanner.plan(videoCodec: "hevc", audioCodec: "aac", isHDR: false, profile: .localPlayback).strategy, .directPlay) }
    func testProbeJSONParsing() throws {
        let data = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","codec_long_name":null,"channels":null,"channel_layout":null,"tags":null,"disposition":{}},{"index":2,"codec_type":"audio","codec_name":"aac","codec_long_name":null,"channels":2,"channel_layout":"stereo","tags":{"language":"eng"},"disposition":{"default":1}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try FFprobeService.parse(data).streams.count, 2)
    }
    func testProbeDefaultAudioSelection() throws {
        let streams = [FFprobeStream(index: 1, codec_type: "audio", codec_name: "aac", codec_long_name: nil, channels: 2, channel_layout: nil, tags: ["language":"fra"], disposition: [:]), FFprobeStream(index: 2, codec_type: "audio", codec_name: "aac", codec_long_name: nil, channels: 2, channel_layout: nil, tags: ["language":"eng"], disposition: ["default":1])]
        XCTAssertEqual(FFprobeService.preferredAudio(from: streams)?.index, 2)
    }
    func testProbeLanguageFallback() {
        let stream = FFprobeStream(index: 4, codec_type: "audio", codec_name: "aac", codec_long_name: nil, channels: 2, channel_layout: nil, tags: ["language":"eng"], disposition: [:])
        XCTAssertEqual(FFprobeService.preferredAudio(from: [stream], preferredLanguage: "eng")?.index, 4)
    }
    func testExplicitAudioMapping() { XCTAssertEqual(FFprobeService.arguments(audioIndex: 4), ["-map","0:v:0","-map","0:4"]) }
    func testSubtitleMapping() { XCTAssertEqual(FFprobeService.arguments(audioIndex: 4, subtitleIndex: 7), ["-map","0:v:0","-map","0:4","-map","0:7"]) }
    func testNoAudioMapping() { XCTAssertEqual(FFprobeService.arguments(audioIndex: nil), ["-map","0:v:0"]) }
    func testOutputNamesUnicode() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("映画 🎬.mkv")
        let reservation = try OutputReservation.reserve(for: source)
        XCTAssertTrue(reservation.destination.lastPathComponent.contains("airplay"))
    }
    func testTerminalStates() {
        XCTAssertTrue(MediaItemState.ready.isTerminal)
        XCTAssertTrue(MediaItemState.failed("x").isTerminal)
        XCTAssertFalse(MediaItemState.transcoding(0.4).isTerminal)
    }
}
