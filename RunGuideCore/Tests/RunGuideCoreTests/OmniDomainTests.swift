import XCTest
@testable import RunGuideCore

final class OmniDomainTests: XCTestCase {

    let truth = OmniDomain(pmax: 1300, cp: 320, wPrime: 22000, a: 18)

    private func curve(from m: OmniDomain, upTo maxSeconds: Int = 7200, noise: Double = 0) -> PowerCurve {
        let secs = OmniDomain.fitDurations.filter { $0 <= maxSeconds }
        let values = secs.enumerated().map { i, s -> Double? in
            // Deterministic ± noise so the test is repeatable.
            m.power(at: Double(s)) * (1 + noise * (i.isMultiple(of: 2) ? 1 : -1))
        }
        return PowerCurve(secs: secs, values: values)
    }

    func testModelShape() {
        // Bounded by Pmax at the very start, CP-like through the middle, fading past 30 minutes.
        XCTAssertLessThan(truth.power(at: 1), 1300)
        XCTAssertGreaterThan(truth.power(at: 1), 1200)
        XCTAssertEqual(truth.power(at: 1800), 320 + 22000.0 / 1800, accuracy: 0.5)
        XCTAssertEqual(truth.power(at: 3600), 320 + 22000.0 / 3600 - 18 * log(2), accuracy: 0.5)
        XCTAssertLessThan(truth.power(at: 7200), truth.power(at: 3600))
        XCTAssertEqual(truth.ftp, truth.power(at: 3600))
    }

    func testRecoversKnownParameters() throws {
        let fit = try XCTUnwrap(OmniDomain.fit(curve: curve(from: truth)))
        XCTAssertEqual(fit.model.cp, 320, accuracy: 3)
        XCTAssertEqual(fit.model.wPrime, 22000, accuracy: 800)
        XCTAssertEqual(fit.model.pmax, 1300, accuracy: 40)
        XCTAssertEqual(fit.model.a, 18, accuracy: 2)
        XCTAssertTrue(fit.model.fittedLong)
        XCTAssertGreaterThan(fit.r2, 0.999)
    }

    func testCopesWithNoise() throws {
        let fit = try XCTUnwrap(OmniDomain.fit(curve: curve(from: truth, noise: 0.02)))
        XCTAssertEqual(fit.model.cp, 320, accuracy: 15)
        XCTAssertEqual(fit.model.ftp, truth.ftp, accuracy: 15)
    }

    func testNoLongEffortsAssumesNoFade() throws {
        let fit = try XCTUnwrap(OmniDomain.fit(curve: curve(from: truth, upTo: 1200)))
        XCTAssertFalse(fit.model.fittedLong)
        XCTAssertEqual(fit.model.a, 0)
        XCTAssertEqual(fit.model.cp, 320, accuracy: 8)
    }

    func testRejectsSparseCurves() {
        XCTAssertNil(OmniDomain.fit(curve: PowerCurve(secs: [300, 600, 1200], values: [380, 350, 330])))
        // No sprint data.
        XCTAssertNil(OmniDomain.fit(curve: curve(from: truth).filtered(minSeconds: 60)))
    }

    func testProfileFallsBackToTwoParameter() throws {
        let sprintless = curve(from: truth).filtered(minSeconds: 60)
        let p = try XCTUnwrap(PowerProfile.fitBest(curve: sprintless))
        XCTAssertNil(p.omni)
        XCTAssertEqual(p.ftp, p.cp)
        let full = try XCTUnwrap(PowerProfile.fitBest(curve: curve(from: truth)))
        XCTAssertNotNil(full.omni)
        XCTAssertEqual(full.ftp, full.omni!.ftp)
    }

    func testNelderMeadFindsAMinimum() {
        let x = NelderMead.minimise({ p in pow(p[0] - 3, 2) + pow(p[1] + 1, 2) }, from: [0, 0], steps: [1, 1])
        XCTAssertEqual(x[0], 3, accuracy: 1e-4)
        XCTAssertEqual(x[1], -1, accuracy: 1e-4)
    }
}

private extension PowerCurve {
    func filtered(minSeconds: Int) -> PowerCurve {
        let keep = secs.indices.filter { secs[$0] >= minSeconds }
        return PowerCurve(secs: keep.map { secs[$0] }, values: keep.map { values[$0] })
    }
}
