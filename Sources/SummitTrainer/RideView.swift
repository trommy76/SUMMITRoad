import SwiftUI

struct WorkoutChart: View {
    let workout: Workout
    let ftp: Double
    let elapsed: Int
    let samples: [Sample]

    var body: some View {
        Canvas { ctx, size in
            let total = Double(max(1, workout.totalSeconds))
            var maxW = ftp * 1.4
            for seg in workout.segments {
                maxW = max(maxW, seg.startWatts(ftp: ftp) * 1.1, seg.endWatts(ftp: ftp) * 1.1)
            }
            func x(_ t: Double) -> CGFloat { CGFloat(t / total) * size.width }
            func y(_ w: Double) -> CGFloat { size.height - CGFloat(w / maxW) * size.height }

            var t = 0.0
            for seg in workout.segments {
                let d = Double(seg.seconds)
                let sw = seg.erg ? seg.startWatts(ftp: ftp) : ftp
                let ew = seg.erg ? seg.endWatts(ftp: ftp) : ftp
                var p = Path()
                p.move(to: CGPoint(x: x(t), y: size.height))
                p.addLine(to: CGPoint(x: x(t), y: y(sw)))
                p.addLine(to: CGPoint(x: x(t + d), y: y(ew)))
                p.addLine(to: CGPoint(x: x(t + d), y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(seg.kind.color.opacity(0.85)))
                t += d
            }

            var l = Path()
            l.move(to: CGPoint(x: 0, y: y(ftp)))
            l.addLine(to: CGPoint(x: size.width, y: y(ftp)))
            ctx.stroke(l, with: .color(.white.opacity(0.8)), lineWidth: 1)
            ctx.draw(Text("FTP \(Int(ftp))").font(.caption.bold()).foregroundColor(.white),
                     at: CGPoint(x: size.width - 36, y: y(ftp) - 9))

            if samples.count > 1 {
                var pp = Path()
                for (i, s) in samples.enumerated() {
                    let pt = CGPoint(x: x(Double(s.t)), y: y(Double(s.power)))
                    if i == 0 { pp.move(to: pt) } else { pp.addLine(to: pt) }
                }
                ctx.stroke(pp, with: .color(.green), lineWidth: 1.5)
            }

            var m = Path()
            m.move(to: CGPoint(x: x(Double(elapsed)), y: 0))
            m.addLine(to: CGPoint(x: x(Double(elapsed)), y: size.height))
            ctx.stroke(m, with: .color(.yellow), lineWidth: 2)
        }
        .background(Color(white: 0.10))
    }
}

struct RideView: View {
    @ObservedObject var s: RideSession
    @EnvironmentObject var app: AppState
    @EnvironmentObject var ble: BLEManager
    @State private var showStats = true
    @State private var confirmEnd = false

    private func hms(_ sec: Int) -> String {
        String(format: "%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60)
    }

    private func cell(_ title: String, _ value: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(.gray)
            Text(value)
                .font(.system(size: 120, weight: .heavy))
                .minimumScaleFactor(0.3).lineLimit(1).monospacedDigit()
                .foregroundColor(.white)
            if let sub = subtitle {
                Text(sub).font(.system(size: 15, weight: .semibold)).foregroundColor(.gray).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var targetText: String {
        if let t = s.targetPower { return "\(t)" }
        return s.segment.erg ? "--" : "FREE"
    }

    private var barColor: Color {
        guard let t = s.targetPower, t > 0 else { return .green }
        let dev = Double(s.power - t) / Double(t)
        if abs(dev) <= 0.05 { return .green }
        return dev < 0 ? .orange : .red
    }

    private var powerBar: some View {
        GeometryReader { g in
            let maxW = Double(max(s.targetPower ?? 150, 100)) * 1.6
            let frac = min(1.0, Double(s.power) / maxW)
            let tf = min(1.0, Double(s.targetPower ?? 0) / maxW)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(barColor).frame(width: max(8, g.size.width * frac))
                if s.targetPower != nil {
                    Rectangle().fill(Color.white).frame(width: 3).offset(x: g.size.width * tf)
                }
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 24)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 34, weight: .heavy)).monospacedDigit()
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        ZStack {
            Color(white: 0.13).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        Text("SUMMIT").font(.system(size: 20, weight: .heavy)).italic().foregroundColor(brandPurple)
                        Text("ROAD").font(.system(size: 20, weight: .light)).italic()
                    }
                    Text(s.workout.name.uppercased()).font(.system(size: 12, weight: .bold)).foregroundColor(.gray)
                }
                .padding(.top, 10)

                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 6) {
                        cell("POWER", "\(s.power)")
                        powerBar
                    }
                    if s.route != nil {
                        cell("SPEED", String(format: "%.1f", s.speedKmh), subtitle: String(format: "km/h · avg %.1f", s.avgSpeedKmh))
                    } else {
                        cell("INTERVAL TIME", formatTime(s.intervalRemaining), subtitle: s.intervalLabel)
                    }
                    cell("HEART RATE", s.hr.map { "\($0)" } ?? "---")
                }
                .frame(maxHeight: .infinity)

                HStack(alignment: .top, spacing: 0) {
                    if s.route != nil {
                        cell("GRADE", String(format: "%.1f%%", s.routeGrade), subtitle: "\(Int(s.routeEle.rounded())) m elevation")
                    } else {
                        cell("TARGET", targetText)
                    }
                    if let rr = s.route {
                        cell("DISTANCE LEFT", String(format: "%.1f", s.routeRemaining / 1000), subtitle: String(format: "km · of %.1f km", rr.length / 1000))
                    } else {
                        cell("WORKOUT TIME", hms(s.elapsed))
                    }
                    cell("CADENCE", s.cadence.map { "\($0)" } ?? "--")
                }
                .frame(maxHeight: .infinity)

                Text(s.message)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.85, blue: 0.35))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 24)
                    .animation(.easeInOut, value: s.message)

                HStack(spacing: 4) {
                    Text("END TIME:")
                    Text(s.endTime, style: .time).bold()
                }
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.gray)
                .padding(.bottom, 6)

                if showStats {
                    HStack(spacing: 0) {
                        if s.route != nil {
                            stat(hms(s.elapsed), "TIME")
                            stat(String(format: "%.1f km", s.distanceM / 1000), "DISTANCE")
                            stat(String(format: "%.1f", s.avgSpeedKmh), "AVG KM/H")
                            stat("\(Int(s.routeClimbed.rounded())) m", "CLIMBED")
                        } else {
                            stat("\(s.intPower)", "INT POW")
                            stat(s.intHR.map { "\($0)" } ?? "---", "INT HR")
                            stat(s.intCadence.map { "\($0)" } ?? "--", "INT CAD")
                        }
                        stat("\(Int(s.tss.rounded()))", "TSS")
                        stat("\(Int(s.kj.rounded()))", "TOTAL KJ")
                        stat("\(Int(s.np.rounded()))", "NP")
                        stat("\(Int(s.avgPower.rounded()))", "AVG POW")
                    }
                    .padding(.vertical, 8)
                    .background(Color(white: 0.16))
                }

                if let rr = s.route {
                    RouteChart(route: rr.route, highlight: rr.startM...rr.endM, position: rr.startM + s.distanceM, legend: true).frame(height: 190)
                } else {
                    WorkoutChart(workout: s.workout, ftp: s.ftp, elapsed: s.elapsed, samples: s.samples)
                        .frame(height: 190)
                }

                controls
            }
            .foregroundColor(.white)

            if let c = s.countdown {
                Text("\(c)")
                    .font(.system(size: 260, weight: .black))
                    .foregroundColor(.white.opacity(0.35))
                    .allowsHitTesting(false)
            }
            if s.state == .ready { readyOverlay }
            if s.state == .waiting { waitingOverlay }
        }
        .confirmationDialog("End this workout?", isPresented: $confirmEnd) {
            Button("End & Save Ride") { s.end() }
            Button("Discard Ride", role: .destructive) { app.discardSession() }
            Button("Keep Riding", role: .cancel) {}
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if s.state == .running || s.state == .paused {
                Button(s.state == .paused ? "Resume" : "Pause") { s.togglePause() }
                    .keyboardShortcut(.space, modifiers: [])
                if s.route == nil {
                    Button("Skip Interval") { s.skipInterval() }
                    Button("−5%") { s.adjustIntensity(-0.05) }
                    Text("\(Int((s.intensityScale * 100).rounded()))%").monospacedDigit().frame(width: 50)
                    Button("+5%") { s.adjustIntensity(0.05) }
                }
            }
            Spacer()
            Toggle("Voice", isOn: $s.voice).toggleStyle(.checkbox)
            Toggle("Stats", isOn: $showStats).toggleStyle(.checkbox)
            Button("End") { if s.state == .ready || s.state == .waiting { app.discardSession() } else { confirmEnd = true } }
        }
        .padding(10)
        .background(Color(white: 0.09))
    }

    private var waitingOverlay: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(s.workout.name).font(.system(size: 28, weight: .heavy)).foregroundColor(.gray)
                Text("Start pedalling to begin").font(.system(size: 44, weight: .heavy))
                Text("The clock, the intervals and the trainer's resistance start as soon as you do.")
                    .foregroundColor(.gray).multilineTextAlignment(.center).frame(maxWidth: 520)
                HStack(spacing: 40) {
                    VStack { Text("\(s.waitingPower)").font(.system(size: 56, weight: .bold)).monospacedDigit(); Text("WATTS").font(.caption).foregroundColor(.gray) }
                    VStack { Text(s.waitingCadence.map { "\($0)" } ?? "–").font(.system(size: 56, weight: .bold)).monospacedDigit(); Text("RPM").font(.caption).foregroundColor(.gray) }
                }
                HStack(spacing: 16) {
                    Button("Cancel") { app.discardSession() }
                    Button("Start Now") { s.begin() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(40)
        }
    }

    private var readyOverlay: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(s.workout.name).font(.system(size: 34, weight: .heavy))
                Text(s.workout.note ?? s.workout.kind.blurb).foregroundColor(.gray).multilineTextAlignment(.center).frame(maxWidth: 520)
                HStack(spacing: 28) {
                    VStack { Text(formatTime(s.totalSeconds)).font(.title.bold()); Text("DURATION").font(.caption).foregroundColor(.gray) }
                    if let rr = s.route {
                        VStack { Text(String(format: "%.1f km", rr.length / 1000)).font(.title.bold()); Text("DISTANCE").font(.caption).foregroundColor(.gray) }
                        VStack { Text("\(Int(rr.route.ascent(from: rr.startM, to: rr.endM).rounded())) m").font(.title.bold()); Text("CLIMBING").font(.caption).foregroundColor(.gray) }
                    } else if !s.workout.kind.isTest {
                        VStack { Text("\(Int(s.workout.estimatedTSS.rounded()))").font(.title.bold()); Text("EST. TSS").font(.caption).foregroundColor(.gray) }
                    }
                    VStack { Text("\(Int(s.ftp)) W").font(.title.bold()); Text(s.workout.kind.isTest ? "EST. FTP" : "FTP").font(.caption).foregroundColor(.gray) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(ble.demoMode ? "Demo trainer (simulated)" : (ble.hasTrainer ? "Trainer: \(ble.trainerName ?? "connected")" : "No trainer connected. Open Devices or enable Demo mode"),
                          systemImage: ble.hasTrainer ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(ble.hasTrainer ? .green : .orange)
                    Label(ble.demoMode ? "Heart rate simulated" : (ble.hrName.map { "Heart rate: \($0)" } ?? "No heart-rate monitor (optional)"),
                          systemImage: ble.hrName != nil || ble.demoMode ? "heart.fill" : "heart")
                        .foregroundColor(ble.hrName != nil || ble.demoMode ? .green : .gray)
                    if ble.hasTrainer && !ble.demoMode {
                        Label(ble.powerOnly ? "Power-only device: you'll need to match targets manually" : (ble.ergReady ? "ERG control ready" : "Waiting for ERG control…"),
                              systemImage: "dial.medium")
                            .foregroundColor(ble.ergReady ? .green : .gray)
                    }
                }
                HStack(spacing: 16) {
                    Button("Cancel") { app.discardSession() }
                    Button(action: { s.armStart() }) {
                        Text("Start Workout").font(.title2.bold()).padding(.horizontal, 30).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!ble.hasTrainer)
                }
            }
            .padding(40)
        }
    }
}
