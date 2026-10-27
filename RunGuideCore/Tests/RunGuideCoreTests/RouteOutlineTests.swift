import XCTest
@testable import RunGuideCore

final class RouteOutlineTests: XCTestCase {

    func testDecodesGooglesReferencePolyline() throws {
        let points = try XCTUnwrap(RouteOutline.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@"))
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].lat, 38.5, accuracy: 1e-6)
        XCTAssertEqual(points[0].lon, -120.2, accuracy: 1e-6)
        XCTAssertEqual(points[1].lat, 40.7, accuracy: 1e-6)
        XCTAssertEqual(points[1].lon, -120.95, accuracy: 1e-6)
        XCTAssertEqual(points[2].lat, 43.252, accuracy: 1e-6)
        XCTAssertEqual(points[2].lon, -126.453, accuracy: 1e-6)
    }

    func testRejectsTruncatedPolyline() {
        // A latitude with no longitude after it.
        XCTAssertNil(RouteOutline.decodePolyline("_p~iF"))
        XCTAssertEqual(RouteOutline.decodePolyline("")?.count, 0)
    }

    func testSimplifiesARealRouteAndKeepsItsEnds() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "point-to-point-16.05km", withExtension: "gpx",
                                                  subdirectory: "Routes"))
        let route = try RouteParser.parse(data: Data(contentsOf: url), fallbackName: "p2p")
        XCTAssertGreaterThan(route.points.count, 80)

        let outline = RouteOutline.simplify(route.points, maxPoints: 60)
        XCTAssertLessThanOrEqual(outline.count, 60)
        XCTAssertGreaterThan(outline.count, 10)
        XCTAssertEqual(outline.first, route.points.first)
        XCTAssertEqual(outline.last, route.points.last)
    }

    func testShortLinesAreLeftAlone() {
        let line = [GeoPoint(lat: 51.4, lon: -0.2), GeoPoint(lat: 51.41, lon: -0.21)]
        XCTAssertEqual(RouteOutline.simplify(line), line)
    }

    func testNormalisedFitsTheUnitSquareKeepingProportions() {
        // Twice as tall (north-south) as it is wide.
        let line = [GeoPoint(lat: 51.0, lon: 0.0),
                    GeoPoint(lat: 51.02, lon: 0.0),
                    GeoPoint(lat: 51.02, lon: 0.01 / cos(51.0 * .pi / 180))]
        let n = RouteOutline.normalised(line)
        XCTAssertEqual(n.count, 3)
        for p in n {
            XCTAssertGreaterThanOrEqual(p.x, -1e-9); XCTAssertLessThanOrEqual(p.x, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, -1e-9); XCTAssertLessThanOrEqual(p.y, 1 + 1e-9)
        }
        // The north-south side spans the full square; north is at the top (small y).
        XCTAssertEqual(n[0].y, 1, accuracy: 1e-6)
        XCTAssertEqual(n[1].y, 0, accuracy: 1e-6)
        // The east-west side is narrower and centred.
        let width = n[2].x - n[1].x
        XCTAssertLessThan(width, 0.9)
        XCTAssertEqual(n[1].x, (1 - width) / 2, accuracy: 1e-6)
    }
}
