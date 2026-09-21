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
}
