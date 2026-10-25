import Foundation

/// One sample of the run, written as a FIT "record".
public struct TrackPoint: Hashable {
    public let time: Date
    public let latitude: Double?
    public let longitude: Double?
    public let altitude: Double?
    /// Cumulative distance in metres, as measured by the session.
    public let distance: Double
    /// Metres per second, if GPS knows it.
    public let speed: Double?
    public let heartRate: Int?
    /// Watts, from a power meter.
    public let power: Int?
    /// Revolutions per minute, from a power meter or cadence sensor.
    public let cadence: Int?

    public init(time: Date, latitude: Double?, longitude: Double?, altitude: Double?,
                distance: Double, speed: Double?, heartRate: Int?, power: Int? = nil, cadence: Int? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.distance = distance
        self.speed = speed
        self.heartRate = heartRate
        self.power = power
        self.cadence = cadence
    }
}

public struct TimerEvent: Hashable {
    public enum Kind: Hashable { case start, stop }
    public let time: Date
    public let kind: Kind
}

public struct RecordedLap: Hashable {
    public let index: Int
    public let stepIndex: Int
    public let label: String
    public let kind: StepKind
    public let trigger: LapTrigger
    public let start: Date
    public let end: Date
    /// Moving time, pauses excluded.
    public let timerTime: Double
    public let distance: Double
    public let maxSpeed: Double?
    public let averageHeartRate: Int?
    public let maxHeartRate: Int?
    public let startLatitude: Double?
    public let startLongitude: Double?
    public var power = PowerSummary()

    public var averageSpeed: Double? { timerTime > 0 ? distance / timerTime : nil }
    public var elapsedTime: Double { end.timeIntervalSince(start) }
}

/// Power and cadence over a stretch of points. Cadence averages leave out coasting (zero).
public struct PowerSummary: Hashable, Sendable {
    public var average: Int?
    public var max: Int?
    public var normalized: Int?
    public var averageCadence: Int?
    public var maxCadence: Int?

    public init() {}

    public init(points: [TrackPoint]) {
        let watts = points.compactMap(\.power)
        average = PowerMath.average(watts)
        max = watts.max()
        normalized = PowerMath.normalized(watts)
        let cadence = points.compactMap(\.cadence)
        averageCadence = PowerMath.average(cadence.filter { $0 > 0 })
        maxCadence = cadence.max()
    }
}

public struct ActivityRecording: Hashable {
    public let name: String
    public var sport: RecordSport = .run
    public let start: Date
    public let end: Date
    public let points: [TrackPoint]
    public let laps: [RecordedLap]
    public let events: [TimerEvent]
    public let totalDistance: Double
    public let totalTimerTime: Double

    public var elapsedTime: Double { end.timeIntervalSince(start) }
    public var averageSpeed: Double? { totalTimerTime > 0 ? totalDistance / totalTimerTime : nil }
    public var maxSpeed: Double? { points.compactMap(\.speed).max() }
    public var averageHeartRate: Int? { Self.average(points.compactMap(\.heartRate)) }
    public var maxHeartRate: Int? { points.compactMap(\.heartRate).max() }
    public var power: PowerSummary { PowerSummary(points: points) }

    static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}

/// Collects everything that happens during a run so it can be saved as a FIT file.
/// Pure bookkeeping: the app feeds it points, pauses and laps with real timestamps.
public final class ActivityRecorder {
    public let name: String
    public let start: Date
    public let sport: RecordSport

    public private(set) var points: [TrackPoint] = []
    public private(set) var laps: [RecordedLap] = []
    public private(set) var events: [TimerEvent] = []

    private var lapStart: Date
    private var lapPoints: [TrackPoint] = []
    private var paused = false

    public init(name: String, start: Date, sport: RecordSport = .run) {
        self.name = name
        self.start = start
        self.sport = sport
        self.lapStart = start
        events.append(TimerEvent(time: start, kind: .start))
    }

    public func addPoint(_ point: TrackPoint) {
        guard !paused else { return }
        points.append(point)
        lapPoints.append(point)
    }

    public func pause(at time: Date) {
        guard !paused else { return }
        paused = true
        events.append(TimerEvent(time: time, kind: .stop))
    }

    public func resume(at time: Date) {
        guard paused else { return }
        paused = false
        events.append(TimerEvent(time: time, kind: .start))
    }

    /// Call when the session engine closes a lap.
    public func closeLap(_ lap: Lap, at time: Date) {
        let heartRates = lapPoints.compactMap(\.heartRate)
        let first = lapPoints.first { $0.latitude != nil && $0.longitude != nil }
        var recorded = RecordedLap(
            index: laps.count,
            stepIndex: lap.stepIndex,
            label: lap.label,
            kind: lap.kind,
            trigger: lap.trigger,
            start: lapStart,
            end: max(time, lapStart),
            timerTime: lap.duration,
            distance: lap.distance,
            maxSpeed: lapPoints.compactMap(\.speed).max(),
            averageHeartRate: ActivityRecording.average(heartRates),
            maxHeartRate: heartRates.max(),
            startLatitude: first?.latitude,
            startLongitude: first?.longitude
        )
        recorded.power = PowerSummary(points: lapPoints)
        laps.append(recorded)
        lapStart = time
        lapPoints = []
    }

    public func finish(at time: Date, totalDistance: Double, totalTimerTime: Double) -> ActivityRecording {
        if paused { resume(at: time) }
        events.append(TimerEvent(time: time, kind: .stop))
        return ActivityRecording(
            name: name,
            sport: sport,
            start: start,
            end: max(time, start),
            points: points,
            laps: laps,
            events: events,
            totalDistance: totalDistance,
            totalTimerTime: totalTimerTime
        )
    }
}
