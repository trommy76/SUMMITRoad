import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Colour for a gradient: flat is blue, then green, yellow, orange and red as it gets steeper. The colours blend
/// smoothly between those steps, so a road hovering around one boundary doesn't look like noise.
func gradeColor(_ g: Double) -> Color {
    let stops: [(Double, (Double, Double, Double))] = [
        (0.5, (0.35, 0.55, 0.80)),    // flat: blue
        (2.5, (0.25, 0.72, 0.55)),    // gentle: green
        (4.5, (0.85, 0.75, 0.20)),    // moderate: yellow
        (7.0, (0.95, 0.55, 0.15)),    // hard: orange
        (10.0, (0.90, 0.25, 0.25))]   // very hard: red
    if g <= stops[0].0 { let c = stops[0].1; return Color(red: c.0, green: c.1, blue: c.2) }
    for i in 1..<stops.count where g <= stops[i].0 {
        let (g0, c0) = stops[i - 1], (g1, c1) = stops[i]
        let f = (g - g0) / (g1 - g0)
        return Color(red: c0.0 + (c1.0 - c0.0) * f, green: c0.1 + (c1.1 - c0.1) * f, blue: c0.2 + (c1.2 - c0.2) * f)
    }
    let c = stops.last!.1
    return Color(red: c.0, green: c.1, blue: c.2)
}

/// Colour key for the gradient colours.
struct GradeLegend: View {
    private let items: [(String, Double)] = [("flat", 0), ("2–3%", 2.5), ("4–5%", 4.5), ("6–7%", 7), ("10%+", 10)]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.0) { it in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(gradeColor(it.1)).frame(width: 10, height: 10)
                    Text(it.0).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
    }
}

/// The route's elevation profile, coloured by gradient so you can see how hard each part is before you reach it.
/// `highlight` dims everything outside the chosen section. `position` puts a bike on the road at the rider's spot and
/// dims the part already ridden.
struct RouteChart: View {
    let route: Route
    var highlight: ClosedRange<Double>?
    var position: Double?
    var legend = false

    var body: some View {
        Canvas { ctx, size in
            guard route.points.count > 1, route.totalDistance > 0 else { return }
            let lo = route.minElevation, hi = max(route.maxElevation, lo + 20)
            let pad = (hi - lo) * 0.18
            let total = route.totalDistance
            func x(_ d: Double) -> CGFloat { CGFloat(d / total) * size.width }
            func y(_ e: Double) -> CGFloat { size.height - CGFloat((e - (lo - pad)) / (hi - lo + 2 * pad)) * size.height }
            for i in 0..<(route.points.count - 1) {
                let a = route.points[i], b = route.points[i + 1]
                var p = Path()
                p.move(to: CGPoint(x: x(a.d), y: size.height))
                p.addLine(to: CGPoint(x: x(a.d), y: y(a.ele)))
                p.addLine(to: CGPoint(x: x(b.d) + 0.6, y: y(b.ele)))
                p.addLine(to: CGPoint(x: x(b.d) + 0.6, y: size.height))
                p.closeSubpath()
                var opacity = (highlight.map { $0.contains(a.d) } ?? true) ? 0.95 : 0.22
                if let pos = position, a.d < pos { opacity *= 0.45 }                  // already ridden
                ctx.fill(p, with: .color(gradeColor(a.grade).opacity(opacity)))
            }
            if let pos = position {
                let clamped = min(max(0, pos), total)
                let px = x(clamped)
                let py = y(route.sample(at: clamped).ele)
                var line = Path()
                line.move(to: CGPoint(x: px, y: py)); line.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 2)
                if let bike = ctx.resolveSymbol(id: 0) {
                    let w = bike.size.width, h = bike.size.height
                    let bx = min(max(w / 2, px), size.width - w / 2)
                    ctx.draw(bike, at: CGPoint(x: bx, y: max(h / 2, py - h / 2 - 1)))
                }
            }
        } symbols: {
            ZStack {
                Circle().fill(Color.black.opacity(0.75)).frame(width: 34, height: 34)
                Image(systemName: "bicycle").font(.system(size: 21, weight: .bold)).foregroundColor(.white)
            }
            .tag(0)
        }
        .background(Color(white: 0.10))
        .overlay(alignment: .topTrailing) { if legend { GradeLegend().padding(6) } }
    }
}

// MARK: - Routes section of the Workouts screen

struct RoutesSection: View {
    @EnvironmentObject var store: Store
    @State private var selected: Route?
    @State private var importURL: URL?
    @State private var importName = ""
    @State private var importError = ""

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GPX file (a route or a recorded ride with elevation)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = ""
        importName = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        importURL = url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Routes").font(.title3.bold())
            Text("Ride a GPX route in simulation mode: the trainer's resistance follows the road's gradient, so your effort decides your speed. Pick any section to fit the time you have.")
                .font(.callout).foregroundColor(.gray)
            if !store.routes.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(store.routes) { r in
                        Button { selected = r } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(r.name, systemImage: "map").font(.headline)
                                Text(String(format: "%.1f km · %d m climbing · %d–%d m", r.totalDistance / 1000, Int(r.ascent.rounded()),
                                            Int(r.minElevation.rounded()), Int(r.maxElevation.rounded())))
                                    .font(.callout).foregroundColor(.gray)
                                RouteChart(route: r).frame(height: 56).cornerRadius(6)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.17)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("Import GPX…") { chooseFile() }
                Button("Open Routes Folder") { NSWorkspace.shared.open(store.routesDir) }
                if store.routes.isEmpty { Text("No routes yet. Import a GPX file to get started.").foregroundColor(.gray) }
            }
            if !importError.isEmpty { Text(importError).font(.caption).foregroundColor(.orange) }
        }
        .sheet(item: $selected) { r in RouteDetail(route: r) { selected = nil } }
        .sheet(isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Name this route").font(.title2.bold())
                TextField("Route name", text: $importName).frame(width: 320)
                Text("The file is copied into this app's data folder on your Mac. It is never uploaded or synced.")
                    .font(.caption).foregroundColor(.gray)
                HStack {
                    Button("Cancel") { importURL = nil }
                    Spacer()
                    Button("Import") {
                        if let url = importURL {
                            do { try store.importRoute(from: url, name: importName) }
                            catch { importError = error.localizedDescription }
                        }
                        importURL = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Choosing a section and starting

struct RouteDetail: View {
    let route: Route
    let close: () -> Void
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @State private var startKm = 0.0
    @State private var endKm = 0.0
    @State private var effort = 0.65
    @State private var confirmDelete = false

    private var totalKm: Double { route.totalDistance / 1000 }
    private var ftp: Double { store.profile.ftp ?? 200 }
    private var weight: Double { store.profile.riderWeightKg ?? 80 }
    private var seconds: Double {
        RoutePhysics.estimatedSeconds(route: route, from: startKm * 1000, to: endKm * 1000, power: ftp * effort, mass: weight)
    }
    private func hm(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 3600, (Int(s) % 3600) / 60) }

    private func fit(minutes: Double) {
        endKm = RoutePhysics.endDistance(route: route, from: startKm * 1000, seconds: minutes * 60, power: ftp * effort, mass: weight) / 1000
    }

    var body: some View {
        let minutes = seconds / 60
        VStack(alignment: .leading, spacing: 12) {
            Text("ROUTE · SIMULATION").font(.caption.bold()).foregroundColor(.gray)
            Text(route.name).font(.title.bold())
            Text(String(format: "%.1f km · %d m climbing · steepest %.0f%%", totalKm, Int(route.ascent.rounded()), route.points.map { $0.grade }.max() ?? 0))
                .foregroundColor(.gray)

            RouteChart(route: route, highlight: (startKm * 1000)...(max(startKm, endKm) * 1000), legend: true).frame(height: 130).cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Start at \(String(format: "%.1f", startKm)) km"); Spacer() }
                Slider(value: $startKm, in: 0...max(0.5, totalKm - 1), step: 0.1)
                    .onChange(of: startKm) { v in if endKm < v + 1 { endKm = min(totalKm, v + 1) } }
                HStack { Text("Finish at \(String(format: "%.1f", endKm)) km"); Spacer() }
                Slider(value: $endKm, in: 1...max(1.1, totalKm), step: 0.1)
                    .onChange(of: endKm) { v in if startKm > v - 1 { startKm = max(0, v - 1) } }
            }

            HStack {
                Text("Fit to").foregroundColor(.gray)
                ForEach([60.0, 75.0, 90.0], id: \.self) { m in Button("\(Int(m)) min") { fit(minutes: m) } }
                Spacer()
                Button("Whole route") { startKm = 0; endKm = totalKm }
            }

            Picker("Effort", selection: $effort) {
                Text("Easy 55%").tag(0.55)
                Text("Endurance 65%").tag(0.65)
                Text("Tempo 80%").tag(0.80)
                Text("Hard 95%").tag(0.95)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text(String(format: "%.1f km", max(0, endKm - startKm))).font(.title2.bold())
                    Text("DISTANCE").font(.caption).foregroundColor(.gray)
                }
                VStack(alignment: .leading) {
                    Text("\(Int(route.ascent(from: startKm * 1000, to: endKm * 1000).rounded())) m").font(.title2.bold())
                    Text("CLIMBING").font(.caption).foregroundColor(.gray)
                }
                VStack(alignment: .leading) {
                    Text(hm(seconds)).font(.title2.bold()).foregroundColor((60...90).contains(minutes) ? .green : .orange)
                    Text("EST. TIME AT \(Int((ftp * effort).rounded())) W").font(.caption).foregroundColor(.gray)
                }
                Spacer()
                Stepper("Rider + bike: \(Int(weight)) kg",
                        value: Binding(get: { weight }, set: { store.profile.riderWeightKg = $0 }), in: 40...200, step: 1)
                    .frame(width: 230)
            }
            Text("The time is an estimate from your power, the road's gradient and your weight. In the ride it comes from your actual power.")
                .font(.caption).foregroundColor(.gray)

            HStack {
                Button("Close", action: close)
                Button("Remove Route", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Start Ride") {
                    close()
                    app.startRoute(RouteRide(route: route, startM: startKm * 1000, endM: endKm * 1000, mass: weight), effort: effort)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(endKm - startKm < 0.9)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear {
            startKm = 0
            endKm = totalKm
            if seconds > 90 * 60 { fit(minutes: 75) }                  // long routes open on a section that fits the time
        }
        .alert("Remove this route?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { store.deleteRoute(route); close() }
        } message: { Text("The GPX file is deleted from this app's data folder. Your original file is not touched.") }
    }
}
