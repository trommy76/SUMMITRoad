import Foundation
import AppKit

/// TEMPORARY: builds a synthetic 20-minute ride so the Garmin/Strava .FIT import can be tested without riding.
enum SampleFIT {
    static func make() -> RideSummary {
        let seconds = 1200
        let start = Date().addingTimeInterval(-Double(seconds) - 60)
        var samples: [Sample] = []
        var powers: [Double] = []
        for t in 0..<seconds {
            let base: Double = t < 300 ? 130 : (t < 900 ? 190 : 140)
            let p = Int(base + 12 * sin(Double(t) / 25) + Double((t * 7) % 9))
            let hr = 105 + min(60, t / 12) + Int(4 * sin(Double(t) / 40))
            let cad = 88 + Int(6 * sin(Double(t) / 18))
            samples.append(Sample(t: t, power: p, hr: hr, cad: cad, target: Int(base), kind: .endurance, seg: 0))
            powers.append(Double(p))
        }
        let avg = powers.reduce(0, +) / Double(powers.count)
        let np = Metrics.normalizedPower(powers)
        let ftp = 200.0
        return RideSummary(
            date: start, workoutName: "SummitRoad Sample Ride", workoutKind: .endurance, plannedID: nil, ftp: ftp,
            plannedSeconds: seconds, durationSeconds: seconds, avgPower: avg, np: np, intensityFactor: np / ftp,
            tss: Metrics.tss(np: np, ftp: ftp, seconds: seconds), kj: powers.reduce(0, +) / 1000,
            avgHR: samples.compactMap { $0.hr }.reduce(0, +) / seconds, maxHR: samples.compactMap { $0.hr }.max(),
            avgCadence: samples.compactMap { $0.cad }.reduce(0, +) / seconds,
            score: nil, feedback: [], ftpResult: nil, stravaID: nil, samples: samples)
    }

    /// Writes the file next to the ride files (not added to ride history), reveals it and opens Garmin's import page.
    @discardableResult
    static func createAndReveal(in dir: URL) -> URL? {
        let url = dir.appendingPathComponent("fit/SummitRoad-sample.fit")
        do {
            try FITEncoder.encode(make()).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        NSWorkspace.shared.open(URL(string: "https://connect.garmin.com/modern/import-data")!)
        return url
    }
}
