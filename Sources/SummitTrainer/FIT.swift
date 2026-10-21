import Foundation

/// Minimal Garmin FIT activity encoder (file_id, record, lap, session, activity).
enum FITEncoder {
    private static let fitEpoch: TimeInterval = 631_065_600   // 1989-12-31 00:00:00 UTC

    private static func crc16(_ data: Data, seed: UInt16 = 0) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc = seed
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    private struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        mutating func u32(_ v: UInt32) {
            data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                     UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        mutating func definition(local: UInt8, global: UInt16, fields: [(UInt8, UInt8, UInt8)]) {
            u8(0x40 | local); u8(0); u8(0)           // header, reserved, little-endian
            u16(global)
            u8(UInt8(fields.count))
            for f in fields { u8(f.0); u8(f.1); u8(f.2) }
        }
    }

    // base types
    private static let tEnum: UInt8 = 0x00, tU8: UInt8 = 0x02, tU16: UInt8 = 0x84
    private static let tU32: UInt8 = 0x86, tU32z: UInt8 = 0x8C

    private static func ts(_ d: Date) -> UInt32 { UInt32(max(0, d.timeIntervalSince1970 - fitEpoch)) }
    private static func u8(_ v: Int?) -> UInt8 { v.map { UInt8(max(0, min(254, $0))) } ?? 0xFF }
    private static func u16(_ v: Double) -> UInt16 { UInt16(max(0, min(65534, v.rounded()))) }

    static func encode(_ r: RideSummary) -> Data {
        var w = Writer()
        let start = r.date
        let end = start.addingTimeInterval(Double(r.durationSeconds))

        // file_id
        w.definition(local: 0, global: 0, fields: [(0, 1, tEnum), (1, 2, tU16), (2, 2, tU16), (3, 4, tU32z), (4, 4, tU32)])
        w.u8(0); w.u8(4); w.u16(255); w.u16(1); w.u32(0x5A17_0001); w.u32(ts(start))

        // record
        // Speed comes from the trainer (km/h). Distance is that speed accumulated once per second.
        let speeds = r.samples.compactMap { $0.speed }
        let hasSpeed = !speeds.isEmpty
        var distance = 0.0                                   // metres
        w.definition(local: 1, global: 20, fields: [(253, 4, tU32), (5, 4, tU32), (6, 2, tU16), (3, 1, tU8), (4, 1, tU8), (7, 2, tU16)])
        for s in r.samples {
            if let v = s.speed { distance += v / 3.6 }
            w.u8(1)
            w.u32(ts(start.addingTimeInterval(Double(s.t))))
            w.u32(hasSpeed ? UInt32(max(0, min(4_294_967_294, (distance * 100).rounded()))) : 0xFFFF_FFFF)   // distance, 0.01 m
            w.u16(s.speed.map { u16($0 / 3.6 * 1000) } ?? 0xFFFF)                                          // speed, 0.001 m/s
            w.u8(UInt8(s.hr.map { max(0, min(254, $0)) } ?? 0xFF))
            w.u8(UInt8(s.cad.map { max(0, min(254, $0)) } ?? 0xFF))
            w.u16(UInt16(max(0, min(65534, s.power))))
        }

        let elapsedMs = UInt32(r.durationSeconds * 1000)
        let totalDistance: UInt32 = hasSpeed ? UInt32(max(0, min(4_294_967_294, (distance * 100).rounded()))) : 0xFFFF_FFFF
        let avgSpeed: UInt16 = hasSpeed ? u16(speeds.reduce(0, +) / Double(speeds.count) / 3.6 * 1000) : 0xFFFF
        let maxSpeed: UInt16 = hasSpeed ? u16((speeds.max() ?? 0) / 3.6 * 1000) : 0xFFFF

        // lap
        w.definition(local: 2, global: 19, fields: [(253, 4, tU32), (2, 4, tU32), (7, 4, tU32), (8, 4, tU32), (0, 1, tEnum), (1, 1, tEnum),
                                                      (9, 4, tU32), (13, 2, tU16), (14, 2, tU16)])
        w.u8(2); w.u32(ts(end)); w.u32(ts(start)); w.u32(elapsedMs); w.u32(elapsedMs); w.u8(9); w.u8(1)
        w.u32(totalDistance); w.u16(avgSpeed); w.u16(maxSpeed)

        // session
        w.definition(local: 3, global: 18, fields: [
            (253, 4, tU32), (2, 4, tU32), (7, 4, tU32), (8, 4, tU32), (5, 1, tEnum), (6, 1, tEnum),
            (20, 2, tU16), (21, 2, tU16), (34, 2, tU16), (16, 1, tU8), (17, 1, tU8), (18, 1, tU8),
            (25, 2, tU16), (26, 2, tU16), (0, 1, tEnum), (1, 1, tEnum),
            (9, 4, tU32), (14, 2, tU16), (15, 2, tU16)])
        w.u8(3); w.u32(ts(end)); w.u32(ts(start)); w.u32(elapsedMs); w.u32(elapsedMs)
        w.u8(2); w.u8(6)                                  // cycling / indoor_cycling
        w.u16(u16(r.avgPower))
        w.u16(u16(Double(r.samples.map { $0.power }.max() ?? 0)))
        w.u16(u16(r.np))
        w.u8(UInt8(u8(r.avgHR))); w.u8(UInt8(u8(r.maxHR))); w.u8(UInt8(u8(r.avgCadence)))
        w.u16(0); w.u16(1)
        w.u8(8); w.u8(1)
        w.u32(totalDistance); w.u16(avgSpeed); w.u16(maxSpeed)

        // activity
        w.definition(local: 4, global: 34, fields: [(253, 4, tU32), (0, 4, tU32), (1, 2, tU16), (2, 1, tEnum), (3, 1, tEnum), (4, 1, tEnum)])
        w.u8(4); w.u32(ts(end)); w.u32(elapsedMs); w.u16(1); w.u8(0); w.u8(26); w.u8(1)

        // header + CRCs
        var header = Writer()
        header.u8(14); header.u8(0x20); header.u16(2132)
        header.u32(UInt32(w.data.count))
        header.data.append(contentsOf: Array(".FIT".utf8))
        let hcrc = crc16(header.data)
        header.u16(hcrc)

        var file = header.data
        file.append(w.data)
        var fw = Writer()
        fw.u16(crc16(file))
        file.append(fw.data)
        return file
    }
}
