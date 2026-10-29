import Foundation

// MARK: - Route (from a GPX file)

/// One sample of a route every `Route.step` metres, with elevation and gradient already smoothed.
struct RoutePoint: Codable {
    var d: Double        // metres from the start of the route
    var ele: Double      // smoothed elevation, metres
    var grade: Double    // smoothed gradient, percent (limited to what a trainer can simulate)
    var lat: Double? = nil   // position on the road, degrees (from the GPX file)
    var lon: Double? = nil
}

struct Route: Identifiable, Codable {
    static let step = 20.0
    static let maxGrade = 15.0       // steepest climb we ask the trainer for
    static let minGrade = -10.0      // descents just feel light, so there is no point asking for more

    var id: String { name }
    var name: String
    var points: [RoutePoint]

    var totalDistance: Double { points.last?.d ?? 0 }

    /// Elevation gained between two distances (metres), from the smoothed profile.
    func ascent(from a: Double, to b: Double) -> Double {
        var up = 0.0
        var i = max(0, Int(a / Route.step))
        while i + 1 < points.count, points[i + 1].d <= b {
            up += max(0, points[i + 1].ele - points[i].ele)
            i += 1
        }
        return up
    }

    func descent(from a: Double, to b: Double) -> Double {
        var down = 0.0
        var i = max(0, Int(a / Route.step))
        while i + 1 < points.count, points[i + 1].d <= b {
            down += max(0, points[i].ele - points[i + 1].ele)
            i += 1
        }
        return down
    }

    var ascent: Double { ascent(from: 0, to: totalDistance) }
    var maxElevation: Double { points.map { $0.ele }.max() ?? 0 }
    var minElevation: Double { points.map { $0.ele }.min() ?? 0 }

    /// Where the road is at a distance along the route (interpolated), if the route came with coordinates.
    func coordinate(at distance: Double) -> (lat: Double, lon: Double)? {
        guard points.count > 1, points[0].lat != nil else { return nil }
        let x = min(max(0, distance), totalDistance)
        let i = min(points.count - 2, Int(x / Route.step))
        guard let la0 = points[i].lat, let lo0 = points[i].lon, let la1 = points[i + 1].lat, let lo1 = points[i + 1].lon else { return nil }
        let f = (x - points[i].d) / max(0.001, points[i + 1].d - points[i].d)
        return (la0 + (la1 - la0) * f, lo0 + (lo1 - lo0) * f)
    }

    /// Elevation and gradient at a distance along the route (interpolated).
    func sample(at distance: Double) -> (ele: Double, grade: Double) {
        guard points.count > 1 else { return (points.first?.ele ?? 0, 0) }
        let x = min(max(0, distance), totalDistance)
        let i = min(points.count - 2, Int(x / Route.step))
        let f = (x - points[i].d) / max(0.001, points[i + 1].d - points[i].d)
        return (points[i].ele + (points[i + 1].ele - points[i].ele) * f,
                points[i].grade + (points[i + 1].grade - points[i].grade) * f)
    }
}

enum GPXError: Error, LocalizedError {
    case unreadable, noPoints, noElevation, tooShort
    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file could not be read as GPX."
        case .noPoints: return "The GPX file has no track or route points."
        case .noElevation: return "The GPX file has no elevation data, so the gradient can't be worked out."
        case .tooShort: return "The route is too short (under 1 km)."
        }
    }
}

/// Reads track points (or route points) with their elevation out of a GPX file.
private final class GPXReader: NSObject, XMLParserDelegate {
    struct Raw { var lat: Double; var lon: Double; var ele: Double? }
    var points: [Raw] = []
    private var current: Raw?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let n = name.lowercased()
        if n == "trkpt" || n == "rtept", let la = Double(attributes["lat"] ?? ""), let lo = Double(attributes["lon"] ?? "") {
            current = Raw(lat: la, lon: lo, ele: nil)
        }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = name.lowercased()
        if n == "ele", current != nil { current?.ele = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if n == "trkpt" || n == "rtept", let c = current { points.append(c); current = nil }
    }
}

enum RouteBuilder {
    static func haversine(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6_371_000.0
        let la1 = a.0 * .pi / 180, la2 = b.0 * .pi / 180
        let dla = la2 - la1, dlo = (b.1 - a.1) * .pi / 180
        let h = sin(dla / 2) * sin(dla / 2) + cos(la1) * cos(la2) * sin(dlo / 2) * sin(dlo / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Reads a GPX file into a smoothed, evenly spaced route.
    static func route(fromGPX data: Data, name: String) throws -> Route {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw GPXError.unreadable }
        guard reader.points.count >= 2 else { throw GPXError.noPoints }
        guard reader.points.contains(where: { $0.ele != nil }) else { throw GPXError.noElevation }

        // Distance along the track and a usable elevation at every point (gaps are filled from the previous point).
        var dist: [Double] = [0], ele: [Double] = [], lats: [Double] = [], lons: [Double] = []
        var lastEle = reader.points.first(where: { $0.ele != nil })!.ele!
        var prev = reader.points[0]
        for (i, p) in reader.points.enumerated() {
            if let e = p.ele { lastEle = e }
            if i > 0 {
                let step = haversine((prev.lat, prev.lon), (p.lat, p.lon))
                if step < 0.5 { continue }                       // ignore stopped / duplicate points
                dist.append(dist.last! + step)
            }
            ele.append(lastEle)
            lats.append(p.lat)
            lons.append(p.lon)
            prev = p
        }
        guard dist.count >= 2, let total = dist.last, total >= 1000 else { throw GPXError.tooShort }
        return route(distance: dist, elevation: ele, name: name, lats: lats, lons: lons)
    }

    /// Resamples to a fixed step and smooths elevation and gradient. Exposed so routes can also be built from numbers (tests).
    static func route(distance dist: [Double], elevation ele: [Double], name: String, lats: [Double]? = nil, lons: [Double]? = nil) -> Route {
        let step = Route.step
        let total = dist.last ?? 0
        let n = Int(total / step) + 1
        // Linear resample.
        var raw: [Double] = []
        var rawLat: [Double] = [], rawLon: [Double] = []
        var j = 0
        for k in 0..<n {
            let x = Double(k) * step
            while j + 1 < dist.count - 1, dist[j + 1] < x { j += 1 }
            let j1 = min(j + 1, dist.count - 1)
            let f = min(1, max(0, (x - dist[j]) / max(0.001, dist[j1] - dist[j])))
            raw.append(ele[j] + (ele[min(j + 1, ele.count - 1)] - ele[j]) * f)
            if let la = lats, let lo = lons, la.count == dist.count, lo.count == dist.count {   // the road itself is not smoothed
                rawLat.append(la[j] + (la[j1] - la[j]) * f)
                rawLon.append(lo[j] + (lo[j1] - lo[j]) * f)
            }
        }
        // GPS elevation is noisy: smooth over roughly 160 m, twice, so gradients (and the trainer's resistance) change gradually.
        func smooth(_ a: [Double], radius: Int) -> [Double] {
            (0..<a.count).map { i in
                let lo = max(0, i - radius), hi = min(a.count - 1, i + radius)
                return a[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            }
        }
        let e = smooth(smooth(raw, radius: 4), radius: 4)
        var pts: [RoutePoint] = []
        for i in 0..<e.count {
            let lo = max(0, i - 4), hi = min(e.count - 1, i + 4)
            let g = (e[hi] - e[lo]) / (Double(hi - lo) * step) * 100
            pts.append(RoutePoint(d: Double(i) * step, ele: e[i], grade: min(Route.maxGrade, max(Route.minGrade, g)),
                                  lat: i < rawLat.count ? rawLat[i] : nil, lon: i < rawLon.count ? rawLon[i] : nil))
        }
        return Route(name: name, points: pts)
    }
}

// MARK: - Riding physics

/// Works out how fast a rider goes from power, gradient and weight (steady state, no coasting inertia).
enum RoutePhysics {
    static let rho = 1.2          // air density, kg/m3
    static let cda = 0.32         // drag area, m2 (hands on the hoods)
    static let crr = 0.005        // rolling resistance
    static let efficiency = 0.975 // drivetrain
    static let g = 9.80665
    static let maxSpeed = 18.0    // m/s (65 km/h): descents stop being interesting beyond this

    /// Speed in m/s for a power (W), gradient (%) and total mass (rider + bike, kg).
    static func speed(power: Double, grade: Double, mass: Double) -> Double {
        let theta = atan(grade / 100)
        let linear = mass * g * (sin(theta) + crr * cos(theta))       // N, grows with speed only through the v term
        let watts = max(0, power) * efficiency
        func f(_ v: Double) -> Double { 0.5 * rho * cda * v * v * v + linear * v - watts }
        var lo = 0.0, hi = maxSpeed
        if f(hi) <= 0 { return hi }
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if f(mid) > 0 { hi = mid } else { lo = mid }
        }
        return max(0.3, (lo + hi) / 2)                                 // never exactly stopped, so progress can't stall forever
    }

    /// Estimated time (seconds) to ride from `a` to `b` metres at a steady power.
    static func estimatedSeconds(route: Route, from a: Double, to b: Double, power: Double, mass: Double) -> Double {
        var t = 0.0
        var x = a
        while x < b {
            let len = min(Route.step, b - x)
            let v = speed(power: power, grade: route.sample(at: x + len / 2).grade, mass: mass)
            t += len / v
            x += len
        }
        return t
    }

    /// The distance at which a ride starting at `a` would take `seconds` at a steady power (capped at the end of the route).
    static func endDistance(route: Route, from a: Double, seconds: Double, power: Double, mass: Double) -> Double {
        var t = 0.0
        var x = a
        while x < route.totalDistance {
            let len = min(Route.step, route.totalDistance - x)
            let dt = len / speed(power: power, grade: route.sample(at: x + len / 2).grade, mass: mass)
            if t + dt >= seconds { return x + len * (seconds - t) / dt }
            t += dt
            x += len
        }
        return route.totalDistance
    }
}

/// A chosen stretch of a route, ready to ride.
struct RouteRide {
    var route: Route
    var startM: Double
    var endM: Double
    var mass: Double            // rider + bike, kg
    var length: Double { endM - startM }
}
