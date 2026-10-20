import SwiftUI
import AppKit

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f
}()

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.17)))
    }
}

// MARK: - Today

struct TodayView: View {
    @Binding var tab: AppTab
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Today").font(.largeTitle.bold())

                Card {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("CURRENT FTP").font(.caption.bold()).foregroundColor(.gray)
                            Text(store.profile.ftp.map { "\(Int($0)) W" } ?? "Not set").font(.system(size: 44, weight: .heavy))
                            if let d = store.profile.ftpDate { Text("Tested \(dayFormatter.string(from: d))").foregroundColor(.gray) }
                        }
                        Spacer()
                        Button(store.profile.ftp == nil ? "Take an FTP Test" : "Retest FTP") { tab = .ftp }
                    }
                }

                if store.profile.ftp == nil {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start here").font(.headline)
                            Text("Take an FTP test so every workout is scaled to you. Then build a plan from the questionnaire. You can also enter a known FTP in Settings.")
                                .foregroundColor(.gray)
                        }
                    }
                }

                if let plan = store.plan, let next = plan.next(), let ftp = store.profile.ftp {
                    let w = plan.workout(for: next, ftp: ftp)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(plan.isMissed(next) ? "NEXT UP (MISSED \(dayFormatter.string(from: next.date)))" : "NEXT WORKOUT · \(dayFormatter.string(from: next.date).uppercased())")
                                .font(.caption.bold()).foregroundColor(.gray)
                            Text(w.name).font(.title.bold())
                            Text("\(next.phase.title) phase · Week \(next.week) of \(plan.weeks)\(next.recoveryWeek ? " · Recovery week" : "")")
                                .foregroundColor(.gray)
                            Text(w.kind.blurb)
                            HStack {
                                Text(formatTime(w.totalSeconds)).font(.headline)
                                if !w.kind.isTest { Text("· est. TSS \(Int(w.estimatedTSS.rounded()))").foregroundColor(.gray) }
                            }
                            WorkoutChart(workout: w, ftp: w.kind.isTest ? w.ftp : ftp, elapsed: -1, samples: [])
                                .frame(height: 120).cornerRadius(8)
                            Button("Start Workout") { app.start(w, planned: next) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                } else if store.profile.ftp != nil {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No training plan yet").font(.headline)
                            Text("Answer a few questions and I'll build an 8-12 week plan.").foregroundColor(.gray)
                            Button("Build My Plan") { tab = .plan }
                        }
                    }
                }

                Card {
                    HStack {
                        Image(systemName: ble.hasTrainer ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundColor(ble.hasTrainer ? .green : .orange)
                        Text(ble.hasTrainer ? "Trainer: \(ble.demoMode ? "Demo" : ble.trainerName ?? "connected")" : "No trainer connected")
                        Spacer()
                        Button("Devices") { tab = .devices }
                    }
                }

                if let ftp = store.profile.ftp {
                    Button("Quick Ride: 60-min Endurance") {
                        app.start(WorkoutLibrary.make(.endurance, level: 1, ftp: ftp, minutes: 60))
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Plan

struct PlanView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @State private var showBuilder = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Training Plan").font(.largeTitle.bold())
                    Spacer()
                    if store.plan != nil {
                        Button("Clear Plan", role: .destructive) { confirmClear = true }
                    }
                    Button(store.plan == nil ? "Build Plan" : "Rebuild Plan") { showBuilder = true }
                }
                if let plan = store.plan, let ftp = store.profile.ftp {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Week \(plan.currentWeek()) of \(plan.weeks) · \(plan.completedCount) of \(plan.workouts.count) workouts done")
                                .font(.headline)
                            Text("Goal: \(plan.questionnaire.goal.title) · \(Int(plan.questionnaire.weeklyHours)) h/week · adjustment \(plan.levelAdjust >= 0 ? "+" : "")\(plan.levelAdjust)")
                                .foregroundColor(.gray)
                            Text("The plan adapts after each ride: strong scores raise difficulty, struggles ease it. FTP retests are scheduled at the start of each new block.")
                                .font(.callout).foregroundColor(.gray)
                        }
                    }
                    ForEach(1...plan.weeks, id: \.self) { wk in
                        let items = plan.workouts.filter { $0.week == wk }
                        if let first = items.first {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Week \(wk) · \(first.phase.title)\(first.recoveryWeek ? " · Recovery" : "")")
                                    .font(.headline).padding(.top, 8)
                                ForEach(items) { item in
                                    planRow(plan: plan, item: item, ftp: ftp)
                                }
                            }
                        }
                    }
                } else if store.profile.ftp != nil {
                    Text("No plan yet. Tap Build Plan to answer a few questions.").foregroundColor(.gray)
                } else {
                    Text("No plan yet. Tap Build Plan and enter your FTP to create one.").foregroundColor(.gray)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showBuilder) { QuestionnaireView() }
        .alert("Are you sure you want to clear your training plan?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Plan", role: .destructive) { store.plan = nil }
        } message: {
            Text("Planned workouts are removed. Your ride history and FTP are kept.")
        }
    }

    @ViewBuilder
    private func planRow(plan: TrainingPlan, item: PlannedWorkout, ftp: Double) -> some View {
        let w = plan.workout(for: item, ftp: ftp)
        let done = item.completedDate != nil
        let missed = plan.isMissed(item)
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : (missed ? "xmark.circle" : "circle"))
                .foregroundColor(done ? .green : (missed ? .red : .gray))
            VStack(alignment: .leading) {
                Text(w.name + (item.isLong ? " (long)" : "")).font(.body.bold())
                Text("\(dayFormatter.string(from: item.date)) · \(formatTime(w.totalSeconds))" + (w.kind.isTest ? "" : " · TSS \(Int(w.estimatedTSS.rounded()))"))
                    .font(.caption).foregroundColor(.gray)
            }
            Spacer()
            if let sc = item.completedScore { Text("Score \(Int(sc.rounded()))").foregroundColor(.green) }
            if !done {
                Button("Ride") { app.start(w, planned: item) }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.17)))
    }
}

struct QuestionnaireView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: Store
    @State private var q = Questionnaire()
    @State private var ftpText = ""

    private let dayNames: [(Int, String)] = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build Your Plan").font(.title.bold())
            Text("Like TrainerRoad's Plan Builder, these answers decide your phases (Base, Build, Specialty), weekly volume and how fast the workouts progress.")
                .foregroundColor(.gray).font(.callout)
            Form {
                HStack {
                    Text("FTP (watts)")
                    TextField("e.g. 220", text: $ftpText).frame(width: 90)
                    Text(store.profile.ftp == nil ? "Enter your FTP or take an FTP test first." : "Plan workouts are scaled to this.")
                        .font(.caption).foregroundColor(.gray)
                }
                Picker("What's your main goal?", selection: $q.goal) {
                    ForEach(Goal.allCases) { Text($0.title).tag($0) }
                }
                Picker("Training experience", selection: $q.experience) {
                    ForEach(Experience.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Hours per week you can train: \(Int(q.weeklyHours))")
                    Slider(value: $q.weeklyHours, in: 3...12, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Which days can you ride?")
                    HStack {
                        ForEach(dayNames, id: \.0) { d in
                            Toggle(d.1, isOn: Binding(
                                get: { q.availableDays.contains(d.0) },
                                set: { on in if on { q.availableDays.insert(d.0) } else { q.availableDays.remove(d.0) } }))
                            .toggleStyle(.button)
                        }
                    }
                }
                Picker("Longest ride you can fit in", selection: $q.longestRideMinutes) {
                    ForEach([60, 90, 120, 150, 180], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Plan length", selection: $q.weeks) {
                    ForEach([8, 10, 12], id: \.self) { Text("\($0) weeks").tag($0) }
                }
                Picker("How are sleep, stress and recovery?", selection: $q.progression) {
                    ForEach(Progression.allCases) { Text($0.title).tag($0) }
                }
                DatePicker("Start date", selection: $q.startDate, displayedComponents: .date)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Quick Plan (defaults)") { create(Questionnaire()) }
                    .disabled(enteredFTP == nil)
                Button("Create Plan") { create(q) }
                    .buttonStyle(.borderedProminent)
                    .disabled(q.availableDays.isEmpty || enteredFTP == nil)
            }
        }
        .padding(24)
        .frame(width: 640, height: 600)
        .onAppear {
            if let p = store.plan { q = p.questionnaire; q.startDate = Date() }
            if let f = store.profile.ftp { ftpText = String(Int(f)) }
        }
    }

    private var enteredFTP: Double? {
        guard let f = Double(ftpText.trimmingCharacters(in: .whitespaces)), f >= 50, f <= 600 else { return nil }
        return f
    }

    private func create(_ questionnaire: Questionnaire) {
        guard let ftp = enteredFTP else { return }
        if store.profile.ftp != ftp { store.setFTP(ftp, method: "Manual entry") }
        store.plan = PlanBuilder.generate(questionnaire, ftp: ftp)
        dismiss()
    }
}

// MARK: - FTP test

struct FTPTestView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @State private var estimate: Double = 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("FTP Test").font(.largeTitle.bold())
                Text("FTP is the highest power you can sustain for about an hour. Your zones and every workout are scaled from it, so test at the start of each block (every 4-6 weeks).")
                    .foregroundColor(.gray)
                HStack {
                    Text("Estimated FTP (sets the ramp's starting power)")
                    TextField("Watts", value: $estimate, format: .number).frame(width: 80)
                    Text("W")
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ramp Test (~20-25 min)").font(.title2.bold())
                        Text(WorkoutKind.ftpRamp.blurb)
                        Text("Pedal as the power steps up every minute and ride until you can't hold the target. Rested legs, a fan on, and fuelled is best.")
                            .foregroundColor(.gray)
                        Button("Start Ramp Test") { app.start(WorkoutLibrary.rampTest(estimatedFTP: max(80, estimate))) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("20-Minute Test (~75 min)").font(.title2.bold())
                        Text(WorkoutKind.ftp20.blurb)
                        Text("The big 20 minutes is free-ride (no ERG). Shift gears to find your best even pace. Don't start too hard.")
                            .foregroundColor(.gray)
                        Button("Start 20-Minute Test") { app.start(WorkoutLibrary.twentyMinuteTest(estimatedFTP: max(80, estimate))) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if !store.profile.ftpHistory.isEmpty {
                    Text("FTP history").font(.title2.bold()).padding(.top, 8)
                    ForEach(store.profile.ftpHistory.reversed()) { e in
                        HStack {
                            Text(dayFormatter.string(from: e.date))
                            Spacer()
                            Text(e.method).foregroundColor(.gray)
                            Text("\(Int(e.ftp)) W").bold()
                        }
                        .padding(8)
                    }
                }
            }
            .padding(24)
        }
        .onAppear { if let f = store.profile.ftp { estimate = f } }
    }
}

// MARK: - History & report

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(store.rides, selection: $selected) { r in
                VStack(alignment: .leading) {
                    Text(r.workoutName).bold()
                    HStack {
                        Text(dayFormatter.string(from: r.date)).foregroundColor(.gray)
                        Spacer()
                        if let s = r.score { Text("\(Int(s.total.rounded()))").foregroundColor(.green) }
                        if let f = r.ftpResult { Text("\(Int(f)) W").foregroundColor(.orange) }
                    }.font(.caption)
                }
                .tag(r.id)
            }
            .frame(width: 300)
            Divider()
            if let id = selected, let r = store.rides.first(where: { $0.id == id }) {
                RideReportView(rideID: r.id, fallback: r, isReview: false)
            } else {
                Text("Select a ride").foregroundColor(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ScoreRing: View {
    let score: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 14)
            Circle().trim(from: 0, to: CGFloat(score / 100))
                .stroke(score >= 80 ? Color.green : (score >= 60 ? Color.yellow : Color.orange),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack {
                Text("\(Int(score.rounded()))").font(.system(size: 52, weight: .heavy))
                Text(FeedbackEngine.tier(score).uppercased()).font(.caption.bold()).foregroundColor(.gray)
            }
        }
        .frame(width: 160, height: 160)
    }
}

struct RideReportView: View {
    let rideID: UUID
    let fallback: RideSummary
    let isReview: Bool
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var strava: StravaClient

    private var ride: RideSummary {
        store.rides.first(where: { $0.id == rideID }) ?? (app.review?.id == rideID ? app.review! : fallback)
    }

    private func bar(_ title: String, _ value: Double?) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            if let v = value {
                ProgressView(value: min(100, v), total: 100).tint(v >= 80 ? .green : (v >= 60 ? .yellow : .orange))
                Text("\(Int(v.rounded()))").frame(width: 40, alignment: .trailing).monospacedDigit()
            } else {
                Text("no data").foregroundColor(.gray)
                Spacer()
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        let r = ride
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.workoutName).font(.largeTitle.bold())
                        Text(dayFormatter.string(from: r.date) + " · " + formatTime(r.durationSeconds)).foregroundColor(.gray)
                    }
                    Spacer()
                    if isReview { Button("Done") { app.review = nil }.buttonStyle(.borderedProminent) }
                }

                if let f = r.ftpResult {
                    Card {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("YOUR NEW FTP").font(.caption.bold()).foregroundColor(.gray)
                                Text("\(Int(f)) W").font(.system(size: 56, weight: .heavy))
                            }
                            Spacer()
                            if Int(store.profile.ftp ?? 0) == Int(f) {
                                Label("Applied", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                            } else {
                                Button("Use This FTP") { app.applyFTP(f, from: r) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                if let s = r.score {
                    Card {
                        HStack(spacing: 24) {
                            ScoreRing(score: s.total)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Training Score").font(.title2.bold())
                                bar("Completion", s.completion)
                                bar("Power accuracy", s.power)
                                bar("Cadence", s.cadence)
                                bar("Heart rate", s.heartRate)
                                Text("In target (±5%) \(Int(s.timeInTarget.rounded()))% of the time")
                                    .font(.caption).foregroundColor(.gray)
                            }
                        }
                    }
                }

                Card {
                    HStack {
                        metric("AVG POWER", "\(Int(r.avgPower.rounded()))")
                        metric("NP", "\(Int(r.np.rounded()))")
                        metric("IF", String(format: "%.2f", r.intensityFactor))
                        metric("TSS", "\(Int(r.tss.rounded()))")
                        metric("KJ", "\(Int(r.kj.rounded()))")
                        metric("AVG HR", r.avgHR.map { "\($0)" } ?? "--")
                        metric("AVG CAD", r.avgCadence.map { "\($0)" } ?? "--")
                    }
                }

                SampleChart(samples: r.samples).frame(height: 180).cornerRadius(8)

                if !r.feedback.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Coach Feedback").font(.title2.bold())
                            ForEach(Array(r.feedback.enumerated()), id: \.offset) { _, line in
                                Text("• " + line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Card {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Strava").font(.headline)
                            if let id = r.stravaID {
                                Text("Uploaded (activity \(id))").foregroundColor(.green)
                            } else if !strava.connected {
                                Text("Not connected. Link Strava in Settings.").foregroundColor(.gray)
                            } else {
                                Text(app.uploadMessage.isEmpty ? "Ready to upload" : app.uploadMessage).foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        Button("Upload to Strava") { Task { await app.uploadToStrava(r) } }
                            .disabled(!strava.connected || r.stravaID != nil)
                        Button("Send to Strava (manual)") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.fitURL(for: r)])
                            NSWorkspace.shared.open(URL(string: "https://www.strava.com/upload/select")!)
                        }
                        Button("Reveal .FIT") { NSWorkspace.shared.activateFileViewerSelecting([store.fitURL(for: r)]) }
                    }
                }

                Card {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Garmin Connect").font(.headline)
                            Text("Opens the Garmin import page and shows the .FIT file in Finder. Drag it onto the page; Garmin can then sync it on to Strava.")
                                .font(.callout).foregroundColor(.gray)
                        }
                        Spacer()
                        Button("Send to Garmin") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.fitURL(for: r)])
                            NSWorkspace.shared.open(URL(string: "https://connect.garmin.com/modern/import-data")!)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct SampleChart: View {
    let samples: [Sample]
    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let maxP = Double(max(samples.map { max($0.power, $0.target ?? 0) }.max() ?? 100, 100)) * 1.15
            let n = Double(samples.count - 1)
            func x(_ i: Int) -> CGFloat { CGFloat(Double(i) / n) * size.width }
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(v / maxP) * size.height }

            var tgt = Path()
            tgt.move(to: CGPoint(x: 0, y: size.height))
            for (i, s) in samples.enumerated() { tgt.addLine(to: CGPoint(x: x(i), y: y(Double(s.target ?? 0)))) }
            tgt.addLine(to: CGPoint(x: size.width, y: size.height))
            tgt.closeSubpath()
            ctx.fill(tgt, with: .color(Color.blue.opacity(0.5)))

            var pw = Path()
            for (i, s) in samples.enumerated() {
                let pt = CGPoint(x: x(i), y: y(Double(s.power)))
                if i == 0 { pw.move(to: pt) } else { pw.addLine(to: pt) }
            }
            ctx.stroke(pw, with: .color(.green), lineWidth: 1.2)

            let hrs = samples.enumerated().filter { $0.element.hr != nil }
            if hrs.count > 1 {
                var hp = Path()
                for (k, item) in hrs.enumerated() {
                    let pt = CGPoint(x: x(item.offset), y: y(Double(item.element.hr ?? 0)))
                    if k == 0 { hp.move(to: pt) } else { hp.addLine(to: pt) }
                }
                ctx.stroke(hp, with: .color(.red.opacity(0.8)), lineWidth: 1)
            }
        }
        .background(Color(white: 0.10))
        .overlay(alignment: .topTrailing) {
            Text("blue = target · green = power · red = heart rate").font(.caption2).foregroundColor(.gray).padding(6)
        }
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var store: Store

    private var stateText: String {
        switch ble.bluetoothState {
        case .poweredOn: return "Bluetooth is on"
        case .poweredOff: return "Bluetooth is off. Turn it on in System Settings."
        case .unauthorized: return "Bluetooth permission denied. Allow SummitRoad in System Settings > Privacy & Security > Bluetooth."
        case .unsupported: return "Bluetooth LE is not supported on this Mac."
        default: return "Bluetooth is starting…"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Devices").font(.largeTitle.bold())
                Text(stateText).foregroundColor(ble.bluetoothState == .poweredOn ? .green : .orange)

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connected").font(.headline)
                        HStack {
                            Image(systemName: "bicycle")
                            Text("Trainer: " + (ble.trainerName ?? "none"))
                            if ble.ergReady { Text("ERG ready").foregroundColor(.green) }
                            if ble.powerOnly { Text("power only (no ERG)").foregroundColor(.orange) }
                            Spacer()
                            if ble.trainerName != nil { Button("Disconnect") { ble.disconnectTrainer() } }
                        }
                        HStack {
                            Image(systemName: "heart.fill")
                            Text("Heart rate: " + (ble.hrName ?? "none"))
                            Spacer()
                            if ble.hrName != nil { Button("Disconnect") { ble.disconnectHR() } }
                        }
                        if !ble.statusText.isEmpty { Text(ble.statusText).font(.caption).foregroundColor(.gray) }
                        HStack(spacing: 30) {
                            Text("Power: \(ble.livePower.map { "\($0) W" } ?? "--")")
                            Text("Cadence: \(ble.liveCadence.map { "\($0)" } ?? "--")")
                            Text("HR: \(ble.liveHR.map { "\($0)" } ?? "--")")
                        }
                        .font(.title3.monospacedDigit())
                    }
                }

                HStack {
                    Button(ble.scanning ? "Stop Scanning" : "Scan for Devices") {
                        if ble.scanning { ble.stopScan() } else { ble.startScan() }
                    }
                    .buttonStyle(.borderedProminent)
                    if ble.scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Demo mode (simulated trainer, no hardware)", isOn: $ble.demoMode)
                }

                ForEach(ble.devices) { d in
                    Card {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).bold()
                                Text(d.kindLabel + " · signal \(d.rssi) dBm").font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            if d.isTrainer || d.isPower { Button("Use as Trainer") { ble.connectTrainer(d) } }
                            if d.isHR { Button("Use as HR Monitor") { ble.connectHR(d) } }
                        }
                    }
                }

                Text("Elite Suito: wake it by pedalling, close Zwift/Elite apps and any other app connected to it (a trainer accepts one controller), then scan. It appears as “SUITO”. Any FTMS trainer (Wahoo, Tacx, Saris, JetBlack, etc.) works the same way; power-only devices work without ERG.")
                    .font(.callout).foregroundColor(.gray)
            }
            .padding(24)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var strava: StravaClient
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var sync: SyncClient
    @State private var syncURL = ""
    @State private var syncUser = ""
    @State private var syncPass = ""
    @State private var askUpload = false
    @State private var ftpText = ""
    @State private var secret = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.largeTitle.bold())

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Athlete").font(.headline)
                        HStack {
                            Text("FTP (W)")
                            TextField("e.g. 210", text: $ftpText).frame(width: 90)
                            Button("Save FTP") {
                                if let v = Double(ftpText), v > 50, v < 600 { store.setFTP(v, method: "Manual") }
                            }
                        }
                        Stepper("Max heart rate: \(store.profile.maxHR) bpm", value: $store.profile.maxHR, in: 120...220)
                        Toggle("Voice coaching cues (spoken)", isOn: $store.profile.voiceCues)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Strava").font(.headline)
                        Text("1. Create an API app (link below). 2. Set “Authorization Callback Domain” to localhost. 3. Paste the Client ID and Secret below and click Connect.")
                            .font(.callout).foregroundColor(.gray)
                        Link(destination: URL(string: "https://www.strava.com/settings/api")!) {
                            Label("Open strava.com/settings/api", systemImage: "arrow.up.right.square")
                        }
                        HStack {
                            TextField("Client ID", text: $store.profile.stravaClientID).frame(width: 140)
                            SecureField("Client Secret", text: $secret).frame(width: 260)
                        }
                        HStack {
                            Button("Connect to Strava") {
                                let sec = secret.isEmpty ? (Keychain.get("strava.secret") ?? "") : secret
                                strava.connect(clientID: store.profile.stravaClientID, clientSecret: sec)
                            }
                            if strava.connected { Button("Disconnect") { strava.disconnect() } }
                            if strava.connected { Label(strava.athlete ?? "Connected", systemImage: "checkmark.circle.fill").foregroundColor(.green) }
                        }
                        Toggle("Automatically upload rides when finished", isOn: $store.profile.autoUpload)
                        if !strava.status.isEmpty { Text(strava.status).font(.caption).foregroundColor(.gray) }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Home Server (optional)").font(.headline)
                        Text("Keep your rides, FTP history, training plan, settings and .FIT files on your own SummitRoad server (Docker, on your home network) so other machines see them and you can browse them in a browser. Leave this blank to keep everything only on this Mac.")
                            .font(.callout).foregroundColor(.gray)
                        HStack {
                            TextField("Server address, e.g. 192.168.1.20:8787", text: $syncURL).frame(width: 280)
                            TextField("Username", text: $syncUser).frame(width: 130)
                            SecureField("Password", text: $syncPass).frame(width: 150)
                        }
                        HStack {
                            Button(sync.configured ? "Update Login" : "Connect") {
                                Task {
                                    if await sync.connect(urlString: syncURL, user: syncUser, password: syncPass) {
                                        syncPass = ""
                                        if store.profile.syncUploadOK == nil { askUpload = true }
                                        else { await sync.syncAll(upload: store.profile.syncUploadOK == true, download: true) }
                                    }
                                }
                            }
                            .disabled(sync.busy)
                            if sync.configured {
                                Button("Sync Now") {
                                    Task {
                                        store.profile.syncUploadOK = true
                                        await sync.syncAll(upload: true, download: true)
                                    }
                                }
                                .disabled(sync.busy)
                                if let u = sync.baseURL { Link("Open Dashboard", destination: u) }
                                Button("Disconnect") { sync.disconnect() }.disabled(sync.busy)
                            }
                            if sync.busy { ProgressView().controlSize(.small) }
                        }
                        if !sync.status.isEmpty { Text(sync.status).font(.caption).foregroundColor(.gray) }
                        if sync.configured, let v = sync.serverVersion { Text("Server version: v\(v)").font(.caption).foregroundColor(.gray) }
                        if let t = sync.lastSync { Text("Last sync: \(t.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundColor(.gray) }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Software Update").font(.headline)
                        Text("Installed version: v\(Updater.currentVersion)").foregroundColor(.gray)
                        HStack {
                            Button("Check for Updates") { Task { await updater.check() } }
                                .disabled(updater.busy)
                            if let u = updater.available {
                                Button("Install v\(u.version) and Restart") { Task { await updater.install() } }
                                    .buttonStyle(.borderedProminent).tint(brandPurple)
                                    .disabled(updater.busy)
                                Link("Release notes", destination: u.pageURL)
                            }
                            if updater.busy { ProgressView().controlSize(.small) }
                        }
                        if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundColor(.gray) }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Data").font(.headline)
                        Text("Rides, plan and .FIT files are stored in your Application Support folder.").foregroundColor(.gray)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.dir]) }
                        Button("Open .FIT Folder") { NSWorkspace.shared.open(store.dir.appendingPathComponent("fit")) }
                        Button("Delete Training Plan", role: .destructive) { confirmDelete = true }
                            .disabled(store.plan == nil)
                    }
                }
            }
            .padding(24)
        }
        .alert("Upload your existing data?", isPresented: $askUpload) {
            Button("Upload Everything") {
                store.profile.syncUploadOK = true
                Task { await sync.syncAll(upload: true, download: true) }
            }
            Button("Not Now") {
                store.profile.syncUploadOK = false
                Task { await sync.syncAll(upload: false, download: true) }
            }
        } message: {
            Text("Copy your \(store.rides.count) saved rides, their .FIT files, FTP history, training plan and settings to this server profile? Anything already on the server is downloaded here too, and for the plan and settings the most recent change wins. You can upload later with Sync Now.")
        }
        .alert("Are you sure you want to delete your training plan?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Plan", role: .destructive) { store.plan = nil }
        } message: {
            Text("Planned workouts are removed. Your ride history and FTP are kept.")
        }
        .onAppear {
            if let f = store.profile.ftp { ftpText = String(Int(f)) }
            syncURL = store.profile.syncURL ?? ""
            syncUser = store.profile.syncUser ?? ""
        }
    }
}
