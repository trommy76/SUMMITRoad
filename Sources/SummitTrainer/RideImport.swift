import SwiftUI
import UniformTypeIdentifiers

/// Brings rides recorded elsewhere (a bike computer, Zwift, Strava's export) into the history.
/// Reads .fit and .tcx files, either as they are or gzipped (Strava's bulk export is .fit.gz).
enum RideImportError: Error, LocalizedError {
    case unreadable, unsupported, noPoints, noPower, tooLong
    var errorDescription: String? {
        switch self {
        case .unreadable: return "the file could not be read"
        case .unsupported: return "only .fit and .tcx files are supported"
        case .noPoints: return "no ride data found"
        case .noPower: return "no power data, and no speed or position data to estimate it from"
        case .tooLong: return "the ride is longer than 24 hours"
        }
    }
}

private struct RawPoint {
    var time: Date
    var power: Int?
    var hr: Int?
    var cad: Int?
    var speed: Double?   // km/h
    var alt: Double?
    var lat: Double?
    var lon: Double?
}

enum RideImporter {
    static func ride(from url: URL, ftp: Double, mass: Double = 80) throws -> RideSummary {
        guard var data = try? Data(contentsOf: url) else { throw RideImportError.unreadable }
        var name = url.lastPathComponent
        if data.starts(with: [0x1F, 0x8B]) {
            guard let raw = gunzip(data) else { throw RideImportError.unreadable }
            data = raw
            name = (name as NSString).deletingPathExtension
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let points: [RawPoint]
        if ext == "fit" || (data.count > 12 && data[8..<12].elementsEqual(Array(".FIT".utf8))) {
            points = FITDecoder.points(data)
        } else if ext == "tcx" {
            points = TCXReader.points(data)
        } else {
            throw RideImportError.unsupported
        }
        return try build(points, title: (name as NSString).deletingPathExtension, ftp: ftp, mass: mass)
    }

    private static func gunzip(_ data: Data) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !out.isEmpty ? out : nil
    }

    /// Turns the file's points into the app's 1 Hz samples. A gap of more than 10 s counts as stopped (0 W).
    private static func build(_ raw: [RawPoint], title: String, ftp: Double, mass: Double) throws -> RideSummary {
        let pts = raw.sorted { $0.time < $1.time }
        guard let first = pts.first, let last = pts.last, pts.count > 1 else { throw RideImportError.noPoints }
        let measured = pts.contains(where: { ($0.power ?? 0) > 0 })
        let dur = Int(last.time.timeIntervalSince(first.time))
        guard dur > 0 else { throw RideImportError.noPoints }
        guard dur <= 24 * 3600 else { throw RideImportError.tooLong }

        var samples: [Sample] = []
        samples.reserveCapacity(dur + 1)
        var j = 0
        for t in 0...dur {
            let at = first.time.addingTimeInterval(Double(t))
            while j + 1 < pts.count && pts[j + 1].time <= at { j += 1 }
            let p = pts[j]
            let live = at.timeIntervalSince(p.time) <= 10
            samples.append(Sample(t: t, power: live ? max(0, p.power ?? 0) : 0, hr: live ? p.hr : nil, cad: live ? p.cad : nil,
                                  target: nil, kind: .endurance, seg: 0, speed: live ? p.speed : nil,
                                  alt: p.alt, grade: nil, lat: p.lat, lon: p.lon))
        }

        if !measured {
            guard let est = PowerEstimator.watts(samples, mass: mass) else { throw RideImportError.noPower }
            for i in samples.indices { samples[i].power = est[i] }
        }
        let power = samples.map { Double($0.power) }
        let npv = Metrics.normalizedPower(power)
        let hrs = samples.compactMap { $0.hr }
        let cads = samples.compactMap { $0.cad }.filter { $0 > 0 }
        return RideSummary(
            date: first.time, workoutName: "Imported: \(title)", workoutKind: .adhoc, plannedID: nil,
            ftp: ftp, plannedSeconds: dur, durationSeconds: dur,
            avgPower: Metrics.mean(power), np: npv, intensityFactor: ftp > 0 ? npv / ftp : 0,
            tss: Metrics.tss(np: npv, ftp: ftp, seconds: dur), kj: power.reduce(0, +) / 1000.0,
            avgHR: hrs.isEmpty ? nil : hrs.reduce(0, +) / hrs.count, maxHR: hrs.max(),
            avgCadence: cads.isEmpty ? nil : cads.reduce(0, +) / cads.count,
            score: nil,
            feedback: [measured ? "Imported from a file. It counts towards your levels but has no workout score."
                                : "Imported from a file with no power meter data. Power is estimated from speed and elevation, so treat it as rough. It does not count towards levels unless you turn that on in Settings."],
            ftpResult: nil, stravaID: nil, samples: samples, estimatedPower: measured ? nil : true)
    }

    // MARK: FIT

    fileprivate enum FITDecoder {
        static let epoch: TimeInterval = 631_065_600   // 1989-12-31 UTC

        private struct Field { var num: Int; var size: Int }
        private struct Definition { var big: Bool; var global: Int; var fields: [Field]; var devBytes: Int }

        static func points(_ d: Data) -> [RawPoint] {
            let b = [UInt8](d)
            guard b.count > 14, b[0] >= 12 else { return [] }
            var pos = Int(b[0])
            let end = min(b.count, pos + Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24))
            var defs: [Int: Definition] = [:]
            var out: [RawPoint] = []
            var lastStamp: UInt32 = 0

            func uint(_ at: Int, _ n: Int, big: Bool) -> UInt64 {
                var v: UInt64 = 0
                for i in 0..<n { v |= UInt64(b[at + (big ? n - 1 - i : i)]) << UInt64(8 * i) }
                return v
            }

            while pos < end {
                let h = b[pos]; pos += 1
                if h & 0x80 != 0 {                        // compressed-timestamp data message
                    let local = Int((h >> 5) & 0x03)
                    guard let def = defs[local] else { break }
                    let off = UInt32(h & 0x1F)
                    var stamp = (lastStamp & ~0x1F) | off
                    if off < (lastStamp & 0x1F) { stamp &+= 0x20 }
                    lastStamp = stamp
                    guard pos + size(def) <= b.count else { break }
                    if def.global == 20, let p = record(def, b, pos, stamp: stamp, uint) { out.append(p) }
                    pos += size(def)
                } else if h & 0x40 != 0 {                 // definition
                    let local = Int(h & 0x0F)
                    guard pos + 5 <= b.count else { break }
                    let big = b[pos + 1] == 1
                    let global = Int(uint(pos + 2, 2, big: big))
                    let n = Int(b[pos + 4])
                    pos += 5
                    guard pos + n * 3 <= b.count else { break }
                    var fields: [Field] = []
                    for i in 0..<n { fields.append(Field(num: Int(b[pos + i * 3]), size: Int(b[pos + i * 3 + 1]))) }
                    pos += n * 3
                    var dev = 0
                    if h & 0x20 != 0 {
                        guard pos < b.count else { break }
                        let m = Int(b[pos]); pos += 1
                        guard pos + m * 3 <= b.count else { break }
                        for i in 0..<m { dev += Int(b[pos + i * 3 + 1]) }
                        pos += m * 3
                    }
                    defs[local] = Definition(big: big, global: global, fields: fields, devBytes: dev)
                } else {                                  // data
                    guard let def = defs[Int(h & 0x0F)], pos + size(def) <= b.count else { break }
                    if def.global == 20 {
                        if let p = record(def, b, pos, stamp: nil, uint) {
                            out.append(p)
                        }
                        // keep the running timestamp for compressed headers
                        var at = pos
                        for f in def.fields {
                            if f.num == 253, f.size == 4 { lastStamp = UInt32(uint(at, 4, big: def.big)) }
                            at += f.size
                        }
                    }
                    pos += size(def)
                }
            }
            return out
        }

        private static func size(_ d: Definition) -> Int { d.fields.reduce(0) { $0 + $1.size } + d.devBytes }

        private static func record(_ def: Definition, _ b: [UInt8], _ start: Int, stamp: UInt32?,
                                   _ uint: (Int, Int, Bool) -> UInt64) -> RawPoint? {
            var time = stamp
            var p = RawPoint(time: Date())
            var enhSpeed: Double?, enhAlt: Double?
            var at = start
            for f in def.fields {
                defer { at += f.size }
                guard [1, 2, 4].contains(f.size) else { continue }
                let raw = uint(at, f.size, def.big)
                let invalid: UInt64 = f.size == 1 ? 0xFF : (f.size == 2 ? 0xFFFF : 0xFFFF_FFFF)
                switch f.num {
                case 253: if raw != invalid { time = UInt32(raw) }
                case 0, 1:
                    if f.size == 4, raw != 0x7FFF_FFFF {
                        let deg = Double(Int32(bitPattern: UInt32(raw))) * 180.0 / 2_147_483_648.0
                        if f.num == 0 { p.lat = deg } else { p.lon = deg }
                    }
                case 2: if f.size == 2, raw != invalid { p.alt = Double(raw) / 5 - 500 }
                case 78: if f.size == 4, raw != invalid { enhAlt = Double(raw) / 5 - 500 }
                case 3: if raw != invalid { p.hr = Int(raw) }
                case 4: if raw != invalid { p.cad = Int(raw) }
                case 6: if f.size == 2, raw != invalid { p.speed = Double(raw) / 1000 * 3.6 }
                case 73: if f.size == 4, raw != invalid { enhSpeed = Double(raw) / 1000 * 3.6 }
                case 7: if f.size == 2, raw != invalid { p.power = Int(raw) }
                default: break
                }
            }
            guard let t = time else { return nil }
            p.time = Date(timeIntervalSince1970: epoch + Double(t))
            if let s = enhSpeed { p.speed = s }
            if let a = enhAlt { p.alt = a }
            return p
        }
    }

    // MARK: TCX

    fileprivate final class TCXReader: NSObject, XMLParserDelegate {
        var out: [RawPoint] = []
        private var cur: RawPoint?
        private var text = ""
        private var inHR = false
        private let iso = ISO8601DateFormatter()
        private let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
        }()

        static func points(_ d: Data) -> [RawPoint] {
            let r = TCXReader()
            let p = XMLParser(data: d)
            p.delegate = r
            p.parse()
            return r.out
        }

        private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch local(name) {
            case "Trackpoint": cur = RawPoint(time: Date.distantPast)
            case "HeartRateBpm": inHR = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local(name) {
            case "Time": if cur != nil, let t = isoFrac.date(from: s) ?? iso.date(from: s) { cur?.time = t }
            case "Watts": cur?.power = Int(Double(s) ?? 0)
            case "Value": if inHR { cur?.hr = Int(Double(s) ?? 0) }
            case "HeartRateBpm": inHR = false
            case "Cadence", "RunCadence": if let v = Double(s) { cur?.cad = Int(v) }
            case "AltitudeMeters": cur?.alt = Double(s)
            case "LatitudeDegrees": cur?.lat = Double(s)
            case "LongitudeDegrees": cur?.lon = Double(s)
            case "Speed": if let v = Double(s) { cur?.speed = v * 3.6 }
            case "Trackpoint":
                if let p = cur, p.time != .distantPast { out.append(p) }
                cur = nil
            default: break
            }
        }
    }
}

extension Store {
    /// Imports each file, skipping rides already in the history (same start time, within a minute).
    /// Returns a one-line summary for the user.
    @discardableResult
    func importRides(from urls: [URL]) -> String {
        var added = 0, duplicates = 0
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try RideImporter.ride(from: url, ftp: profile.ftp ?? 0, mass: profile.riderWeightKg ?? 80)
                if rides.contains(where: { abs($0.date.timeIntervalSince(r.date)) < 60 && abs($0.durationSeconds - r.durationSeconds) < 120 }) {
                    duplicates += 1
                    continue
                }
                save(ride: r)
                added += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        rides.sort { $0.date > $1.date }
        var parts: [String] = ["Imported \(added) ride\(added == 1 ? "" : "s")"]
        if duplicates > 0 { parts.append("\(duplicates) already in your history") }
        if !failures.isEmpty { parts.append("skipped " + failures.joined(separator: "; ")) }
        return parts.joined(separator: " · ") + "."
    }
}

extension UTType {
    static let fitFile = UTType(filenameExtension: "fit") ?? .data
    static let tcxFile = UTType(filenameExtension: "tcx") ?? .xml
}

/// Estimates power for a ride recorded without a power meter, from speed, gradient and acceleration.
/// There is no wind, drafting or surface in the file, so this is a rough guide, not a measurement.
enum PowerEstimator {
    /// One estimate per sample (1 Hz), or nil if the ride has neither speed nor position to work from.
    static func watts(_ s: [Sample], mass: Double) -> [Int]? {
        let n = s.count
        guard n > 20 else { return nil }
        // Speed in m/s: recorded, else from the distance between positions.
        var v = [Double](repeating: 0, count: n)
        if s.contains(where: { ($0.speed ?? 0) > 0 }) {
            for i in 0..<n { v[i] = (s[i].speed ?? 0) / 3.6 }
        } else if s.contains(where: { $0.lat != nil && $0.lon != nil }) {
            for i in 1..<n {
                if let a = s[i - 1].lat, let b = s[i - 1].lon, let c = s[i].lat, let d = s[i].lon {
                    v[i] = min(25, haversine(a, b, c, d))
                }
            }
        } else {
            return nil
        }
        v = smooth(v, 2)
        var alt = [Double](repeating: 0, count: n)
        let hasAlt = s.contains { $0.alt != nil }
        if hasAlt {
            var last = s.first(where: { $0.alt != nil })?.alt ?? 0
            for i in 0..<n { if let a = s[i].alt { last = a }; alt[i] = last }
            alt = smooth(alt, 4)
        }
        var dist = [Double](repeating: 0, count: n)
        for i in 1..<n { dist[i] = dist[i - 1] + v[i] }

        var out = [Int](repeating: 0, count: n)
        let reach = 10
        for i in 0..<n {
            let speed = v[i]
            if speed < 0.5 { continue }
            var grade = 0.0
            if hasAlt {
                let a = max(0, i - reach), b = min(n - 1, i + reach)
                let run = dist[b] - dist[a]
                if run > 40 { grade = max(-0.15, min(0.15, (alt[b] - alt[a]) / run)) }
            }
            let a0 = max(0, i - 2), a1 = min(n - 1, i + 2)
            let accel = a1 > a0 ? (v[a1] - v[a0]) / Double(a1 - a0) : 0
            let theta = atan(grade)
            let force = 0.5 * RoutePhysics.rho * RoutePhysics.cda * speed * speed
                + mass * RoutePhysics.g * (sin(theta) + RoutePhysics.crr * cos(theta)) + mass * accel
            let watts = force * speed / RoutePhysics.efficiency
            out[i] = watts > 0 ? Int(min(1500, watts).rounded()) : 0   // freewheeling downhill is 0 W
        }
        return smoothInts(out, 2)
    }

    private static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    private static func smooth(_ x: [Double], _ k: Int) -> [Double] {
        var out = x
        for i in x.indices {
            let a = max(0, i - k), b = min(x.count - 1, i + k)
            out[i] = x[a...b].reduce(0, +) / Double(b - a + 1)
        }
        return out
    }

    private static func smoothInts(_ x: [Int], _ k: Int) -> [Int] {
        smooth(x.map(Double.init), k).map { Int($0.rounded()) }
    }
}
