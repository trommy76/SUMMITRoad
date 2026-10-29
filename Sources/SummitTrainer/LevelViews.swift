import SwiftUI
import AppKit

private let levelRed = Color(red: 0.86, green: 0.15, blue: 0.10)

// MARK: - The image

/// The shareable "Athlete Levels" picture: your levels over a darkened photo, with the ride's power underneath.
struct LevelCardView: View {
    static let size = CGSize(width: 2000, height: 1333)

    let ride: RideSummary
    let before: AthleteLevels
    let after: AthleteLevels
    let background: NSImage?

    private let barX = 620.0, barW = 1180.0

    var body: some View {
        ZStack {
            Color.black
            if let bg = background {
                Image(nsImage: bg).resizable().scaledToFill()
                    .frame(width: Self.size.width, height: Self.size.height).clipped()
                    .saturation(0).opacity(0.38)
            }
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("SUMMIT").font(.system(size: 40, weight: .heavy)).italic().foregroundColor(brandPurple)
                    Text("ROAD").font(.system(size: 40, weight: .light)).italic().foregroundColor(.white)
                    Spacer()
                }
                .padding(.leading, 90).padding(.top, 60)

                Text("Athlete Levels").font(.system(size: 76, weight: .bold)).foregroundColor(.white).padding(.top, 8)
                Text(subtitle).font(.system(size: 34)).foregroundColor(.white.opacity(0.7)).padding(.top, 6)

                VStack(spacing: 34) {
                    ForEach(LevelZone.allCases) { z in row(z) }
                }
                .padding(.top, 70)
                .padding(.leading, 190)

                Spacer(minLength: 0)
                PowerStrip(samples: ride.samples).frame(height: 330)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var subtitle: String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"
        return "\(ride.workoutName) · \(f.string(from: ride.date)) · \(formatTime(ride.durationSeconds)) · NP \(Int(ride.np.rounded())) W · TSS \(Int(ride.tss.rounded()))"
    }

    private func row(_ z: LevelZone) -> some View {
        let v = after[z] ?? 0
        let gain = v - (before[z] ?? 0)
        return HStack(spacing: 0) {
            Text(z.rawValue).font(.system(size: 54, weight: .medium)).foregroundColor(.white).frame(width: 400, alignment: .leading)
            Text(String(format: "%.1f", v)).font(.system(size: 54, weight: .medium)).foregroundColor(.white.opacity(0.85))
                .frame(width: 130, alignment: .leading)
            ZStack(alignment: .leading) {
                ForEach(0..<6) { i in
                    Rectangle().fill(.white.opacity(i == 0 ? 0.5 : 0.22)).frame(width: 2, height: 84)
                        .offset(x: barW * Double(i) / 5)
                }
                Rectangle().fill(levelRed).frame(width: barW * v / 10, height: 40)
                Rectangle().fill(.white).frame(width: 6, height: 60).offset(x: barW * v / 10 - 3)
                if gain >= 0.05 {
                    // Near the right edge the label would run off the picture, so it goes inside the bar instead.
                    let inside = v > 8.6
                    Text(String(format: "+%.1f", gain)).font(.system(size: 40, weight: .bold))
                        .foregroundColor(inside ? .white : Color(red: 0.35, green: 0.9, blue: 0.4))
                        .offset(x: inside ? barW * v / 10 - 130 : barW * v / 10 + 24)
                }
            }
            .frame(width: barW, height: 84, alignment: .leading)
        }
    }
}

/// Power (yellow), target or power fill (blue) and heart rate (red) across the ride, for the foot of the image.
private struct PowerStrip: View {
    let samples: [Sample]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let n = Double(samples.count - 1)
            let maxP = Double(max(samples.map { max($0.power, $0.target ?? 0) }.max() ?? 100, 100)) * 1.1
            let hrs = samples.compactMap { $0.hr }
            let hrMax = Double(max(hrs.max() ?? 0, 100)) * 1.05
            func x(_ i: Int) -> CGFloat { CGFloat(Double(i) / n) * size.width }
            func py(_ w: Int) -> CGFloat { size.height - CGFloat(Double(w) / maxP) * size.height * 0.92 }
            func smooth(_ i: Int) -> Int {
                let lo = max(0, i - 2), hi = min(samples.count - 1, i + 2)
                return samples[lo...hi].map { $0.power }.reduce(0, +) / (hi - lo + 1)
            }

            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            for i in samples.indices { fill.addLine(to: CGPoint(x: x(i), y: py(samples[i].target ?? smooth(i)))) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(Color(red: 0.16, green: 0.65, blue: 0.90)))

            var line = Path()
            for i in samples.indices {
                let p = CGPoint(x: x(i), y: py(smooth(i)))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.stroke(line, with: .color(.yellow), lineWidth: 4)

            if !hrs.isEmpty {
                var h = Path()
                var started = false
                for (i, s) in samples.enumerated() {
                    guard let hr = s.hr else { continue }
                    let p = CGPoint(x: x(i), y: size.height - CGFloat(Double(hr) / hrMax) * size.height * 0.6)
                    if started { h.addLine(to: p) } else { h.move(to: p); started = true }
                }
                ctx.stroke(h, with: .color(Color(red: 0.9, green: 0.15, blue: 0.15)), lineWidth: 4)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.7)).frame(height: 2) }
    }
}

// MARK: - Making and saving the image

enum LevelCard {
    /// The rider's own photos if the backgrounds folder has any, otherwise the ones shipped with the app.
    static func backgroundURLs(userDir: URL) -> [URL] {
        let exts: Set<String> = ["jpg", "jpeg", "png"]
        func images(in dir: URL?) -> [URL] {
            guard let dir else { return [] }
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let own = images(in: userDir)
        return own.isEmpty ? images(in: Bundle.main.resourceURL?.appendingPathComponent("Backgrounds")) : own
    }

    /// The same ride always gets the same photo.
    static func background(for ride: RideSummary, userDir: URL) -> NSImage? {
        let urls = backgroundURLs(userDir: userDir)
        guard !urls.isEmpty else { return nil }
        let pick = Int(ride.id.uuid.0) % urls.count
        return NSImage(contentsOf: urls[pick])
    }

    @MainActor
    static func png(ride: RideSummary, rides: [RideSummary], ftp: Double, userDir: URL) -> Data? {
        let c = Levels.change(for: ride, in: rides, ftp: ftp)
        let view = LevelCardView(ride: ride, before: c.before, after: c.after, background: background(for: ride, userDir: userDir))
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension Store {
    func cardURL(for r: RideSummary) -> URL { dir.appendingPathComponent("cards/\(r.id.uuidString).png") }
    var backgroundsDir: URL { dir.appendingPathComponent("backgrounds", isDirectory: true) }
}

/// Shown on the ride report: the picture, with save, copy and reveal.
struct LevelCardSection: View {
    let ride: RideSummary
    @EnvironmentObject var store: Store
    @State private var image: NSImage?

    var body: some View {
        if ride.samples.count >= 60 {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Athlete Levels").font(.title2.bold())
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().cornerRadius(8)
                        HStack {
                            Button("Save Image…") { save() }
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.writeObjects([image])
                            }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.cardURL(for: ride)]) }
                            Spacer()
                            Text("Saved with this ride").font(.caption).foregroundColor(.gray)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .task(id: ride.id) { make() }
        }
    }

    private func make() {
        let ftp = store.profile.ftp ?? ride.ftp
        var all = store.rides
        if !all.contains(where: { $0.id == ride.id }) { all.append(ride) }
        guard let data = LevelCard.png(ride: ride, rides: all, ftp: ftp, userDir: store.backgroundsDir) else { return }
        let url = store.cardURL(for: ride)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        image = NSImage(data: data)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "SummitRoad levels \(ride.workoutName).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.copyItem(at: store.cardURL(for: ride), to: url)
        }
    }
}

// MARK: - Levels tab

struct LevelsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let ftp = store.profile.ftp
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Levels").font(.largeTitle.bold())
                if let ftp {
                    let now = Levels.levels(rides: store.rides, ftp: ftp)
                    let monthAgo = Levels.levels(rides: store.rides, asOf: Date().addingTimeInterval(-30 * 86400), ftp: ftp)
                    Text("How strong you are in each zone, from 0 to 10, judged on your best effort of the right length in the last \(Levels.windowDays) days. Ride hard efforts and the bars move.")
                        .foregroundColor(.gray)
                    Card {
                        VStack(spacing: 16) {
                            ForEach(LevelZone.allCases) { z in
                                zoneRow(z, level: now[z] ?? 0, change: (now[z] ?? 0) - (monthAgo[z] ?? 0))
                            }
                        }
                    }
                    Text("Levels are measured against your current FTP of \(Int(ftp)) W. Each zone uses the best average power you held for its reference time (\(LevelZone.allCases.map { "\($0.rawValue) \($0.durationText)" }.joined(separator: ", "))), so a zone only moves when a ride includes an effort that long. These are SummitRoad's own estimates, not TrainerRoad's progression levels.")
                        .font(.caption).foregroundColor(.gray)
                } else {
                    Text("Set your FTP first (take an FTP test, or enter it in Settings) so levels can be worked out.")
                        .foregroundColor(.orange)
                }
            }
            .padding(24)
        }
    }

    private func zoneRow(_ z: LevelZone, level: Double, change: Double) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(z.rawValue).font(.headline)
                Text(Levels.bestWatts(z, rides: store.rides).map { "best \(z.durationText): \(Int($0.rounded())) W" } ?? "no \(z.durationText) effort yet")
                    .font(.caption).foregroundColor(.gray)
            }
            .frame(width: 190, alignment: .leading)
            Text(String(format: "%.1f", level)).font(.title2.bold()).monospacedDigit().frame(width: 46, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.2)).frame(height: 14)
                    Rectangle().fill(levelRed).frame(width: g.size.width * level / 10, height: 14)
                    Rectangle().fill(.white).frame(width: 3, height: 22).offset(x: g.size.width * level / 10 - 1.5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 26)
            Group {
                if abs(change) >= 0.05 {
                    Text(String(format: "%+.1f", change)).foregroundColor(change > 0 ? .green : .orange)
                } else {
                    Text("–").foregroundColor(.gray)
                }
            }
            .font(.callout.bold()).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
        .help("Change over the last 30 days is shown on the right.")
    }
}
