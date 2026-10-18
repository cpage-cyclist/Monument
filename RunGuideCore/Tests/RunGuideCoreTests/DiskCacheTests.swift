import XCTest
@testable import RunGuideCore

final class DiskCacheTests: XCTestCase {

    var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunGuideCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTripAndRemove() {
        let cache = DiskCache(folder: folder)
        XCTAssertNil(cache.read("missing"))

        cache.write(Data("hello".utf8), for: CacheKey.streams("i196049903"))
        let entry = cache.read(CacheKey.streams("i196049903"))
        XCTAssertEqual(entry.map { String(decoding: $0.data, as: UTF8.self) }, "hello")
        XCTAssertLessThan(entry?.age() ?? .infinity, 60)

        cache.remove(CacheKey.streams("i196049903"))
        XCTAssertNil(cache.read(CacheKey.streams("i196049903")))
    }

    func testKeysAreSanitised() {
        XCTAssertEqual(DiskCache.fileName(for: "streams-../../etc"), "streams-.._.._etc")
        let cache = DiskCache(folder: folder)
        cache.write(Data("x".utf8), for: "a/b")
        XCTAssertNotNil(cache.read("a/b"))
    }

    func testTrimKeepsNewestMatchingEntries() throws {
        let cache = DiskCache(folder: folder)
        for i in 0..<5 {
            cache.write(Data("\(i)".utf8), for: CacheKey.streams("i\(i)"))
            // Spread the modification dates so "newest" is well defined.
            let url = folder.appendingPathComponent(DiskCache.fileName(for: CacheKey.streams("i\(i)")))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10) * 60)],
                                                  ofItemAtPath: url.path)
        }
        cache.write(Data("list".utf8), for: CacheKey.activityList)

        cache.trim(prefix: CacheKey.streamsPrefix, keep: 2)
        XCTAssertNil(cache.read(CacheKey.streams("i0")))
        XCTAssertNil(cache.read(CacheKey.streams("i2")))
        XCTAssertNotNil(cache.read(CacheKey.streams("i3")))
        XCTAssertNotNil(cache.read(CacheKey.streams("i4")))
        XCTAssertNotNil(cache.read(CacheKey.activityList))
    }

    func testUnloggedPromptPicksNewestRecentUnloggedActivity() throws {
        let json = """
        [
          {"id": "i3", "start_date_local": "2026-10-18T07:00:00", "type": "Ride", "name": "Commute", "moving_time": 2000},
          {"id": "20617938250", "start_date_local": "2026-10-18T09:00:00", "source": "STRAVA"},
          {"id": "i2", "start_date_local": "2026-10-17T08:33:50", "type": "Run", "name": "Parkrun", "moving_time": 2400, "icu_rpe": 8},
          {"id": "i1", "start_date_local": "2026-10-10T06:42:01", "type": "Ride", "name": "Old", "moving_time": 9000}
        ]
        """
        let list = try JSONDecoder().decode([ActivitySummary].self, from: Data(json.utf8))
        let now = try XCTUnwrap(IntervalsDates.parseLocal("2026-10-18T13:45:00"))

        XCTAssertEqual(LogPrompt.unlogged(in: list, now: now)?.id.value, "i3")
        XCTAssertNil(LogPrompt.unlogged(in: list, now: now, dismissed: ["i3"]))
    }
}
