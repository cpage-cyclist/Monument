import Foundation

/// A lap as the head unit or watch recorded it, read from the activity's original FIT file.
/// Times are seconds from the start of the activity, matching the streams' `time`.
public struct DeviceLap: Codable, Equatable, Sendable {
    public var startTime: Double
    public var endTime: Double
    /// Seconds the timer ran (pauses excluded), when the file says.
    public var timerTime: Double?
    /// Metres, when the file says.
    public var distance: Double?
    /// FIT lap intensity: 0 active, 1 rest, 2 warm-up, 3 cool-down.
    public var intensity: Int?

    public init(startTime: Double, endTime: Double, timerTime: Double? = nil,
                distance: Double? = nil, intensity: Int? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.timerTime = timerTime
        self.distance = distance
        self.intensity = intensity
    }

    public var isRest: Bool { intensity == 1 }
}

public enum DeviceLaps {

    /// Device laps are only worth showing over Intervals' detection when there's more than one.
    public static func useful(_ laps: [DeviceLap]?) -> Bool { (laps?.count ?? 0) > 1 }

    /// Builds lap rows from device laps, with the figures worked out from the streams.
    public static func intervals(_ laps: [DeviceLap], streams: ActivityStreams, timeline: Timeline,
                                 ftp: Double?, weight: Double?, isRun: Bool) -> [ActivityInterval] {
        laps.enumerated().map { i, lap in
            var range: ClosedRange<Int>?
            if let a = timeline.index(atTime: lap.startTime), let b = timeline.index(atTime: lap.endTime) {
                // A lap ends where the next starts; keep it off the next lap's first sample.
                let end = (i < laps.count - 1 && b > a + 1) ? b - 1 : b
                if end > a { range = a...end }
            }
            let stats = range.flatMap {
                SelectionStats.compute(streams: streams, timeline: timeline, range: $0,
                                       ftp: ftp, weight: weight, isRun: isRun)
            }
            return ActivityInterval(
                label: "Lap \(i + 1)",
                type: lap.isRest ? "RECOVERY" : "WORK",
                startIndex: range?.lowerBound,
                endIndex: range?.upperBound,
                startTime: lap.startTime,
                endTime: lap.endTime,
                movingTime: lap.timerTime ?? stats?.duration,
                elapsedTime: lap.endTime - lap.startTime,
                distance: lap.distance ?? stats?.distance,
                averagePower: stats?.power?.avg,
                normalizedPower: stats?.normalizedPower,
                maxPower: stats?.power?.max,
                averageHeartRate: stats?.heartRate?.avg,
                maxHeartRate: stats?.heartRate?.max,
                averageCadence: stats?.cadence?.avg,
                averageSpeed: stats?.speed.map { $0.avg / 3.6 },
                trainingLoad: stats?.load,
                intensity: stats?.intensity.map { $0 * 100 },
                decoupling: stats?.decoupling,
                wbalStart: stats?.wbalStart.map { $0 * 1000 },
                wbalEnd: stats?.wbalEnd.map { $0 * 1000 }
            )
        }
    }
}

/// Reads laps out of a FIT activity file (optionally gzipped, as Intervals serves originals).
public enum FITLapReader {

    public enum ReadError: Error { case notFIT, truncated }

    public static func laps(from data: Data) throws -> [DeviceLap] {
        var bytes = [UInt8](data)
        if bytes.count > 2, bytes[0] == 0x1F, bytes[1] == 0x8B {
            guard let unzipped = gunzip(bytes) else { throw ReadError.notFIT }
            bytes = unzipped
        }
        return try parse(bytes)
    }

    // MARK: - Parsing

    private struct FieldDef { let number: UInt8; let size: Int }
    private struct Definition { let global: UInt16; let bigEndian: Bool; let fields: [FieldDef]; let devSize: Int }

    private struct RawLap { var start: UInt32?; var end: UInt32?; var elapsed: UInt32?; var timer: UInt32?
                            var distance: UInt32?; var intensity: UInt8? }

    static func parse(_ b: [UInt8]) throws -> [DeviceLap] {
        guard b.count >= 12 else { throw ReadError.notFIT }
        let headerSize = Int(b[0])
        guard headerSize >= 12, b.count >= headerSize,
              b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 else { throw ReadError.notFIT }
        let dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let end = min(headerSize + dataSize, b.count)

        var defs: [UInt8: Definition] = [:]
        var laps: [RawLap] = []
        var sessionStart: UInt32?
        var firstRecord: UInt32?
        var lastTimestamp: UInt32 = 0
        var p = headerSize

        func uint(_ at: Int, _ size: Int, big: Bool) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<size {
                let byte = UInt64(b[at + (big ? k : size - 1 - k)])
                v = v << 8 | byte
            }
            return v
        }

        while p < end {
            let h = b[p]; p += 1
            if h & 0x80 != 0 {
                // Compressed-timestamp data record.
                let local = (h >> 5) & 0x03
                guard let def = defs[local] else { throw ReadError.truncated }
                let offset = UInt32(h & 0x1F)
                var ts = (lastTimestamp & ~0x1F) | offset
                if ts < lastTimestamp { ts += 0x20 }
                lastTimestamp = ts
                let size = def.fields.reduce(0) { $0 + $1.size } + def.devSize
                guard p + size <= end else { throw ReadError.truncated }
                if def.global == 20, firstRecord == nil { firstRecord = ts }
                p += size
            } else if h & 0x40 != 0 {
                let local = h & 0x0F
                let hasDev = h & 0x20 != 0
                guard p + 5 <= end else { throw ReadError.truncated }
                let big = b[p + 1] == 1
                let global = UInt16(uint(p + 2, 2, big: big))
                let count = Int(b[p + 4]); p += 5
                guard p + count * 3 <= end else { throw ReadError.truncated }
                var fields: [FieldDef] = []
                for _ in 0..<count {
                    fields.append(FieldDef(number: b[p], size: Int(b[p + 1]))); p += 3
                }
                var devSize = 0
                if hasDev {
                    guard p < end else { throw ReadError.truncated }
                    let n = Int(b[p]); p += 1
                    guard p + n * 3 <= end else { throw ReadError.truncated }
                    for _ in 0..<n { devSize += Int(b[p + 1]); p += 3 }
                }
                defs[local] = Definition(global: global, bigEndian: big, fields: fields, devSize: devSize)
            } else {
                guard let def = defs[h & 0x0F] else { throw ReadError.truncated }
                var lap = RawLap()
                var timestamp: UInt32?
                var start: UInt32?
                for f in def.fields {
                    guard p + f.size <= end else { throw ReadError.truncated }
                    defer { p += f.size }
                    guard f.size == 1 || f.size == 2 || f.size == 4 else { continue }
                    let v = uint(p, f.size, big: def.bigEndian)
                    let invalid: UInt64 = f.size == 1 ? 0xFF : f.size == 2 ? 0xFFFF : 0xFFFF_FFFF
                    guard v != invalid else { continue }
                    switch (f.number, f.size) {
                    case (253, 4): timestamp = UInt32(v)
                    case (2, 4): start = UInt32(v)
                    case (7, 4) where def.global == 19: lap.elapsed = UInt32(v)
                    case (8, 4) where def.global == 19: lap.timer = UInt32(v)
                    case (9, 4) where def.global == 19: lap.distance = UInt32(v)
                    case (23, 1) where def.global == 19: lap.intensity = UInt8(v)
                    default: break
                    }
                }
                p += def.devSize
                if let timestamp { lastTimestamp = timestamp }
                switch def.global {
                case 19:
                    lap.start = start
                    lap.end = timestamp
                    laps.append(lap)
                case 18:
                    if sessionStart == nil { sessionStart = start }
                case 20:
                    if firstRecord == nil { firstRecord = timestamp }
                default: break
                }
            }
        }

        // Intervals' time stream starts at the first sample, so measure from there.
        guard let origin = firstRecord ?? sessionStart ?? laps.compactMap(\.start).min() else { return [] }
        return laps.compactMap { raw -> DeviceLap? in
            let elapsed = raw.elapsed.map { Double($0) / 1000 }
            var start = raw.start.map(Double.init)
            var stop = raw.end.map(Double.init)
            if start == nil, let stop, let elapsed { start = stop - elapsed }
            if stop == nil, let start, let elapsed { stop = start + elapsed }
            guard let s = start, let e = stop, e > s else { return nil }
            return DeviceLap(startTime: s - Double(origin),
                             endTime: e - Double(origin),
                             timerTime: raw.timer.map { Double($0) / 1000 },
                             distance: raw.distance.map { Double($0) / 100 },
                             intensity: raw.intensity.map(Int.init))
        }
        .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Gzip

    /// Strips the gzip wrapper and inflates the DEFLATE body.
    static func gunzip(_ b: [UInt8]) -> [UInt8]? {
        guard b.count > 18, b[2] == 8 else { return nil }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 {
            guard p + 2 <= b.count else { return nil }
            p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
        }
        if flags & 0x08 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x10 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x02 != 0 { p += 2 }
        guard p < b.count - 8 else { return nil }
        #if canImport(Darwin)
        // Foundation's .zlib is raw DEFLATE, which is what gzip wraps.
        let body = Data(b[p..<(b.count - 8)]) as NSData
        guard let out = try? body.decompressed(using: .zlib) else { return nil }
        return [UInt8](out as Data)
        #else
        return nil
        #endif
    }
}
