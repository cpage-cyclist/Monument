import Foundation

/// Writes an `ActivityRecording` as a FIT activity file.
///
/// FIT is Garmin's binary format: a 14-byte header, then records that are
/// each either a *definition* (the layout of a message type) or *data* laid
/// out to match it, then a CRC. Field numbers and scales come from Garmin's
/// FIT profile; CI decodes the output with Garmin's own SDK to check it.
public enum FITEncoder {

    // MARK: - Base types (FIT profile)

    enum Base: UInt8 {
        case enumeration = 0x00
        case uint8 = 0x02
        case uint16 = 0x84
        case sint32 = 0x85
        case uint32 = 0x86
        case uint32z = 0x8C

        var size: UInt8 {
            switch self {
            case .enumeration, .uint8: return 1
            case .uint16: return 2
            case .sint32, .uint32, .uint32z: return 4
            }
        }
    }

    struct Field {
        let number: UInt8
        let base: Base
    }

    struct MessageType {
        let local: UInt8
        let global: UInt16
        let fields: [Field]
    }

    // Local message numbers 0–5, one per message type we write.
    static let fileId = MessageType(local: 0, global: 0, fields: [
        Field(number: 0, base: .enumeration),   // type
        Field(number: 1, base: .uint16),        // manufacturer
        Field(number: 2, base: .uint16),        // product
        Field(number: 3, base: .uint32z),       // serial_number
        Field(number: 4, base: .uint32)         // time_created
    ])
    static let event = MessageType(local: 1, global: 21, fields: [
        Field(number: 253, base: .uint32),      // timestamp
        Field(number: 0, base: .enumeration),   // event
        Field(number: 1, base: .enumeration),   // event_type
        Field(number: 4, base: .uint8)          // event_group
    ])
    static let record = MessageType(local: 2, global: 20, fields: [
        Field(number: 253, base: .uint32),      // timestamp
        Field(number: 0, base: .sint32),        // position_lat (semicircles)
        Field(number: 1, base: .sint32),        // position_long (semicircles)
        Field(number: 2, base: .uint16),        // altitude (scale 5, offset 500)
        Field(number: 3, base: .uint8),         // heart_rate
        Field(number: 5, base: .uint32),        // distance (scale 100)
        Field(number: 6, base: .uint16),        // speed (scale 1000)
        Field(number: 4, base: .uint8),         // cadence (rpm)
        Field(number: 7, base: .uint16)         // power (watts)
    ])
    static let lap = MessageType(local: 3, global: 19, fields: [
        Field(number: 254, base: .uint16),      // message_index
        Field(number: 253, base: .uint32),      // timestamp
        Field(number: 0, base: .enumeration),   // event
        Field(number: 1, base: .enumeration),   // event_type
        Field(number: 2, base: .uint32),        // start_time
        Field(number: 3, base: .sint32),        // start_position_lat
        Field(number: 4, base: .sint32),        // start_position_long
        Field(number: 7, base: .uint32),        // total_elapsed_time (scale 1000)
        Field(number: 8, base: .uint32),        // total_timer_time (scale 1000)
        Field(number: 9, base: .uint32),        // total_distance (scale 100)
        Field(number: 13, base: .uint16),       // avg_speed (scale 1000)
        Field(number: 14, base: .uint16),       // max_speed (scale 1000)
        Field(number: 15, base: .uint8),        // avg_heart_rate
        Field(number: 16, base: .uint8),        // max_heart_rate
        Field(number: 23, base: .enumeration),  // intensity
        Field(number: 24, base: .enumeration),  // lap_trigger
        Field(number: 25, base: .enumeration),  // sport
        Field(number: 71, base: .uint16),       // wkt_step_index
        Field(number: 17, base: .uint8),        // avg_cadence
        Field(number: 18, base: .uint8),        // max_cadence
        Field(number: 19, base: .uint16),       // avg_power
        Field(number: 20, base: .uint16),       // max_power
        Field(number: 33, base: .uint16)        // normalized_power
    ])
    static let session = MessageType(local: 4, global: 18, fields: [
        Field(number: 254, base: .uint16),      // message_index
        Field(number: 253, base: .uint32),      // timestamp
        Field(number: 0, base: .enumeration),   // event
        Field(number: 1, base: .enumeration),   // event_type
        Field(number: 2, base: .uint32),        // start_time
        Field(number: 5, base: .enumeration),   // sport
        Field(number: 6, base: .enumeration),   // sub_sport
        Field(number: 7, base: .uint32),        // total_elapsed_time (scale 1000)
        Field(number: 8, base: .uint32),        // total_timer_time (scale 1000)
        Field(number: 9, base: .uint32),        // total_distance (scale 100)
        Field(number: 14, base: .uint16),       // avg_speed (scale 1000)
        Field(number: 15, base: .uint16),       // max_speed (scale 1000)
        Field(number: 16, base: .uint8),        // avg_heart_rate
        Field(number: 17, base: .uint8),        // max_heart_rate
        Field(number: 25, base: .uint16),       // first_lap_index
        Field(number: 26, base: .uint16),       // num_laps
        Field(number: 28, base: .enumeration),  // trigger
        Field(number: 18, base: .uint8),        // avg_cadence
        Field(number: 19, base: .uint8),        // max_cadence
        Field(number: 20, base: .uint16),       // avg_power
        Field(number: 21, base: .uint16),       // max_power
        Field(number: 34, base: .uint16)        // normalized_power
    ])
    static let activity = MessageType(local: 5, global: 34, fields: [
        Field(number: 253, base: .uint32),      // timestamp
        Field(number: 0, base: .uint32),        // total_timer_time (scale 1000)
        Field(number: 1, base: .uint16),        // num_sessions
        Field(number: 2, base: .enumeration),   // type
        Field(number: 3, base: .enumeration),   // event
        Field(number: 4, base: .enumeration),   // event_type
        Field(number: 5, base: .uint32)         // local_timestamp
    ])

    // MARK: - Profile values

    static let fitEpoch: TimeInterval = 631_065_600  // 1989-12-31T00:00:00Z in Unix time
    static let invalidU8: UInt64 = 0xFF
    static let invalidU16: UInt64 = 0xFFFF
    static let invalidU32: UInt64 = 0xFFFF_FFFF
    static let invalidS32: Int64 = 0x7FFF_FFFF

    enum Event: UInt64 { case timer = 0, session = 8, lap = 9, activity = 26 }
    enum EventType: UInt64 { case start = 0, stop = 1, stopAll = 4 }

    // MARK: - Encoding

    public static func encode(_ recording: ActivityRecording, timeZone: TimeZone = .current) -> Data {
        var writer = Writer()

        writer.write(fileId, [4, 255, 1, UInt64(serial(for: recording.start)), timestamp(recording.start)])

        // Records, timer events and laps in time order. Laps are written after
        // the records they cover; ties go event → record → lap.
        enum Item { case event(TimerEvent), point(TrackPoint), lap(RecordedLap) }
        var items: [(Date, Int, Item)] = []
        for e in recording.events { items.append((e.time, 0, .event(e))) }
        for p in recording.points { items.append((p.time, 1, .point(p))) }
        for l in recording.laps { items.append((l.end, 2, .lap(l))) }
        items.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }

        for (_, _, item) in items {
            switch item {
            case .event(let e):
                writer.write(event, [
                    timestamp(e.time),
                    Event.timer.rawValue,
                    (e.kind == .start ? EventType.start : EventType.stopAll).rawValue,
                    0
                ])
            case .point(let p):
                writer.write(record, [
                    timestamp(p.time),
                    semicircles(p.latitude),
                    semicircles(p.longitude),
                    p.altitude.map { clamp(($0 + 500) * 5, max: 0xFFFE) } ?? invalidU16,
                    p.heartRate.map { clamp(Double($0), max: 0xFE) } ?? invalidU8,
                    clamp(p.distance * 100, max: 0xFFFF_FFFE),
                    p.speed.map { clamp($0 * 1000, max: 0xFFFE) } ?? invalidU16,
                    p.cadence.map { clampOrZero(Double($0), max: 0xFE) } ?? invalidU8,
                    p.power.map { clampOrZero(Double($0), max: 0xFFFE) } ?? invalidU16
                ])
            case .lap(let l):
                writer.write(lap, [
                    UInt64(l.index),
                    timestamp(l.end),
                    Event.lap.rawValue,
                    EventType.stop.rawValue,
                    timestamp(l.start),
                    semicircles(l.startLatitude),
                    semicircles(l.startLongitude),
                    clamp(l.elapsedTime * 1000, max: 0xFFFF_FFFE),
                    clamp(l.timerTime * 1000, max: 0xFFFF_FFFE),
                    clamp(l.distance * 100, max: 0xFFFF_FFFE),
                    l.averageSpeed.map { clamp($0 * 1000, max: 0xFFFE) } ?? invalidU16,
                    l.maxSpeed.map { clamp($0 * 1000, max: 0xFFFE) } ?? invalidU16,
                    l.averageHeartRate.map { clamp(Double($0), max: 0xFE) } ?? invalidU8,
                    l.maxHeartRate.map { clamp(Double($0), max: 0xFE) } ?? invalidU8,
                    intensity(l.kind),
                    lapTrigger(l.trigger),
                    recording.sport.fitSport,
                    UInt64(l.stepIndex)
                ] + powerValues(l.power))
            }
        }

        writer.write(session, [
            0,
            timestamp(recording.end),
            Event.session.rawValue,
            EventType.stop.rawValue,
            timestamp(recording.start),
            recording.sport.fitSport,
            0, // generic
            clamp(recording.elapsedTime * 1000, max: 0xFFFF_FFFE),
            clamp(recording.totalTimerTime * 1000, max: 0xFFFF_FFFE),
            clamp(recording.totalDistance * 100, max: 0xFFFF_FFFE),
            recording.averageSpeed.map { clamp($0 * 1000, max: 0xFFFE) } ?? invalidU16,
            recording.maxSpeed.map { clamp($0 * 1000, max: 0xFFFE) } ?? invalidU16,
            recording.averageHeartRate.map { clamp(Double($0), max: 0xFE) } ?? invalidU8,
            recording.maxHeartRate.map { clamp(Double($0), max: 0xFE) } ?? invalidU8,
            0,
            UInt64(recording.laps.count),
            0 // activity_end
        ] + powerValues(recording.power))

        let end = timestamp(recording.end)
        let offset = Int64(timeZone.secondsFromGMT(for: recording.end))
        writer.write(activity, [
            end,
            clamp(recording.totalTimerTime * 1000, max: 0xFFFF_FFFE),
            1,
            0, // manual
            Event.activity.rawValue,
            EventType.stop.rawValue,
            UInt64(max(0, Int64(end) + offset))
        ])

        return writer.finish()
    }

    // MARK: - Helpers

    static func timestamp(_ date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 - fitEpoch).rounded(.down)))
    }

    /// Degrees → semicircles, stored as the two's-complement bit pattern.
    static func semicircles(_ degrees: Double?) -> UInt64 {
        guard let degrees, degrees.isFinite else { return UInt64(UInt32(bitPattern: Int32(invalidS32))) }
        let value = Int32(clamping: Int64((degrees * (2_147_483_648.0 / 180.0)).rounded()))
        return UInt64(UInt32(bitPattern: value))
    }

    static func clamp(_ value: Double, max: UInt64) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(max) { return max }
        return UInt64(value.rounded())
    }

    /// Cadence average/max, then power average, max and normalised, for laps and the session.
    static func powerValues(_ p: PowerSummary) -> [UInt64] {
        [p.averageCadence.map { clampOrZero(Double($0), max: 0xFE) } ?? invalidU8,
         p.maxCadence.map { clampOrZero(Double($0), max: 0xFE) } ?? invalidU8,
         p.average.map { clampOrZero(Double($0), max: 0xFFFE) } ?? invalidU16,
         p.max.map { clampOrZero(Double($0), max: 0xFFFE) } ?? invalidU16,
         p.normalized.map { clampOrZero(Double($0), max: 0xFFFE) } ?? invalidU16]
    }

    /// Like `clamp`, but a real zero (coasting, 0 rpm) stays zero rather than meaning "no value".
    static func clampOrZero(_ value: Double, max: UInt64) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return clamp(value, max: max)
    }

    static func intensity(_ kind: StepKind) -> UInt64 {
        switch kind {
        case .active: return 0
        case .rest: return 1
        case .warmup: return 2
        case .cooldown: return 3
        }
    }

    static func lapTrigger(_ trigger: LapTrigger) -> UInt64 {
        switch trigger {
        case .manual: return 0
        case .time: return 1
        case .distance: return 2
        case .sessionEnd: return 7
        }
    }

    static func serial(for date: Date) -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(date.timeIntervalSince1970)) | 1
    }

    // MARK: - Byte writer

    struct Writer {
        private var body = Data()
        private var defined = Set<UInt8>()

        mutating func write(_ type: MessageType, _ values: [UInt64]) {
            precondition(values.count == type.fields.count, "FIT field count mismatch")
            if !defined.contains(type.local) {
                defined.insert(type.local)
                body.append(0x40 | type.local)          // definition header
                body.append(0)                          // reserved
                body.append(0)                          // little-endian
                appendLE(UInt64(type.global), size: 2)
                body.append(UInt8(type.fields.count))
                for field in type.fields {
                    body.append(field.number)
                    body.append(field.base.size)
                    body.append(field.base.rawValue)
                }
            }
            body.append(type.local)                     // data header
            for (field, value) in zip(type.fields, values) {
                appendLE(value, size: Int(field.base.size))
            }
        }

        private mutating func appendLE(_ value: UInt64, size: Int) {
            for i in 0..<size {
                body.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))))
            }
        }

        func finish() -> Data {
            var header = Data()
            header.append(14)                           // header size
            header.append(0x20)                         // protocol 2.0
            header.append(contentsOf: [0x54, 0x08])     // profile 21.32 (2132), little-endian
            let size = UInt32(body.count)
            header.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * UInt32($0))) })
            header.append(contentsOf: Array(".FIT".utf8))
            let headerCRC = FITEncoder.crc(header)
            header.append(UInt8(headerCRC & 0xFF))
            header.append(UInt8(headerCRC >> 8))

            var file = header
            file.append(body)
            let fileCRC = FITEncoder.crc(file)
            file.append(UInt8(fileCRC & 0xFF))
            file.append(UInt8(fileCRC >> 8))
            return file
        }
    }

    static let crcTable: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400
    ]

    public static func crc(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            var tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]
            tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
