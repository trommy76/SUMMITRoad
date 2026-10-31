import SwiftUI

private let monthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    return f
}()

private let shortDay: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

private let accentGreen = Color(red: 0.20, green: 0.65, blue: 0.20)

private func hoursText(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
}

private enum CalItem: Identifiable {
    case planned(PlannedWorkout)
    case ride(RideSummary)
    var id: UUID {
        switch self {
        case .planned(let p): return p.id
        case .ride(let r): return r.id
        }
    }
}

struct CalendarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var month = Date()
    @State private var openPlanned: PlannedWorkout?
    @State private var openRide: RideSummary?

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private var weeks: [[Date]] {
        guard let monthStart = cal.dateInterval(of: .month, for: month)?.start,
              let monthEnd = cal.date(byAdding: .day, value: -1, to: cal.dateInterval(of: .month, for: month)!.end),
              let first = cal.dateInterval(of: .weekOfYear, for: monthStart)?.start,
              let last = cal.dateInterval(of: .weekOfYear, for: monthEnd)?.end
        else { return [] }
        var days: [Date] = []
        var d = first
        while d < last {
            days.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    private func items(on day: Date) -> [CalItem] {
        var out: [CalItem] = []
        let rides = store.rides.filter { cal.isDate($0.date, inSameDayAs: day) }
        let doneIDs = Set(rides.compactMap { $0.plannedID })
        if let plan = store.plan {
            for p in plan.workouts where cal.isDate(p.date, inSameDayAs: day) && !doneIDs.contains(p.id) {
                out.append(.planned(p))
            }
        }
        out.append(contentsOf: rides.map { .ride($0) })
        return out
    }

    private func ftp() -> Double { store.profile.ftp ?? store.plan?.startFTP ?? 200 }

    private func plannedWorkout(_ p: PlannedWorkout) -> Workout? {
        store.plan?.workout(for: p, ftp: ftp())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdayRow
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(weeks.indices, id: \.self) { i in
                        weekRow(weeks[i])
                        Divider()
                    }
                }
            }
        }
        .sheet(item: $openPlanned) { p in PlannedDetail(planned: p, workout: plannedWorkout(p), ftp: ftp()) { openPlanned = nil } }
        .sheet(item: $openRide) { r in
            VStack(alignment: .trailing, spacing: 0) {
                Button("Close") { openRide = nil }.padding(10)
                RideReportView(rideID: r.id, fallback: r, isReview: false)
            }
            .frame(minWidth: 900, minHeight: 700)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Text(monthFormatter.string(from: month)).font(.title3.bold()).frame(minWidth: 150)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            Spacer()
            Button("Today") { month = Date() }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func shift(_ n: Int) {
        month = cal.date(byAdding: .month, value: n, to: month) ?? month
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
                Text(d).font(.caption).foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
            }
            Color.clear.frame(width: 130, height: 1)
        }
        .padding(.vertical, 8)
    }

    private func weekRow(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(days, id: \.self) { day in
                dayCell(day)
                Divider()
            }
            weekSummary(days)
        }
        .frame(minHeight: 170)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let dayNum = cal.component(.day, from: day)
        let label = dayNum == 1 ? shortDay.string(from: day) : "\(dayNum)"
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: isToday ? .bold : .semibold))
                .foregroundColor(isToday ? .white : (inMonth ? .primary : .gray.opacity(0.5)))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(isToday ? accentGreen : Color.clear))
            ForEach(items(on: day)) { item in
                switch item {
                case .planned(let p): plannedCard(p)
                case .ride(let r): rideCard(r)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func plannedCard(_ p: PlannedWorkout) -> some View {
        let w = plannedWorkout(p)
        let missed = store.plan?.isMissed(p) ?? false
        return Button { openPlanned = p } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(p.phase.title) · Wk \(p.week)\(p.recoveryWeek ? " · Recovery" : "")")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.gray).lineLimit(1)
                if let w = w {
                    WorkoutChart(workout: w, ftp: w.kind.isTest ? w.ftp : ftp(), elapsed: -1, samples: [])
                        .frame(height: 38).cornerRadius(3)
                    Text(w.name).font(.system(size: 12, weight: .bold)).lineLimit(2)
                    HStack {
                        VStack(alignment: .leading) {
                            Text(hoursText(w.totalSeconds)).font(.system(size: 11)).monospacedDigit()
                            Text("DURATION").font(.system(size: 8)).foregroundColor(.gray).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        VStack(alignment: .leading) {
                            Text("\(Int(w.estimatedTSS.rounded()))").font(.system(size: 11)).monospacedDigit()
                            Text("TSS").font(.system(size: 8)).foregroundColor(.gray)
                        }
                        Spacer()
                        if missed { Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red) }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.17)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(missed ? Color.red.opacity(0.6) : Color(white: 0.28)))
        }
        .buttonStyle(.plain)
    }

    private func rideCard(_ r: RideSummary) -> some View {
        Button { openRide = r } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.workoutName).font(.system(size: 12, weight: .bold)).lineLimit(2)
                HStack {
                    VStack(alignment: .leading) {
                        Text(hoursText(r.durationSeconds)).font(.system(size: 11)).monospacedDigit()
                        Text("DURATION").font(.system(size: 8)).foregroundColor(.gray).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    VStack(alignment: .leading) {
                        Text("\(Int(r.tss.rounded()))").font(.system(size: 11)).monospacedDigit()
                        Text("TSS").font(.system(size: 8)).foregroundColor(.gray)
                    }
                    Spacer()
                    if let s = r.score {
                        Text("\(Int(s.total.rounded()))").font(.system(size: 11, weight: .bold)).foregroundColor(.green)
                    }
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.17)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.green.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    private func weekSummary(_ days: [Date]) -> some View {
        let plannedItems = days.flatMap { items(on: $0) }
        var planSec = 0, planTSS = 0.0, doneSec = 0, doneTSS = 0.0
        for item in plannedItems {
            switch item {
            case .planned(let p):
                if let w = plannedWorkout(p) { planSec += w.totalSeconds; planTSS += w.estimatedTSS }
            case .ride(let r):
                doneSec += r.durationSeconds; doneTSS += r.tss
                if let pid = r.plannedID, let p = store.plan?.workouts.first(where: { $0.id == pid }), let w = plannedWorkout(p) {
                    planSec += w.totalSeconds; planTSS += w.estimatedTSS
                }
            }
        }
        let weekNo = cal.component(.weekOfYear, from: days[0])
        return VStack(alignment: .leading, spacing: 6) {
            Text("Wk \(weekNo)").font(.system(size: 13, weight: .bold))
            summaryLine("HOURS", "\(hoursText(doneSec)) / \(hoursText(planSec))")
            summaryLine("TSS", "\(Int(doneTSS.rounded())) / \(Int(planTSS.rounded()))")
            Spacer()
        }
        .padding(10)
        .frame(width: 130, alignment: .topLeading)
    }

    private func summaryLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(.gray)
            Text(value).font(.system(size: 12)).monospacedDigit()
        }
    }
}

private struct PlannedDetail: View {
    let planned: PlannedWorkout
    let workout: Workout?
    let ftp: Double
    let close: () -> Void
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let w = workout {
                Text(shortDay.string(from: planned.date).uppercased()).font(.caption.bold()).foregroundColor(.gray)
                Text(w.name).font(.title.bold())
                Text("\(planned.phase.title) phase · Week \(planned.week)\(planned.recoveryWeek ? " · Recovery week" : "")")
                    .foregroundColor(.gray)
                Text(w.kind.blurb)
                Text("\(formatTime(w.totalSeconds)) · est. TSS \(Int(w.estimatedTSS.rounded()))").font(.headline)
                WorkoutChart(workout: w, ftp: w.kind.isTest ? w.ftp : ftp, elapsed: -1, samples: [])
                    .frame(height: 140).cornerRadius(8)
                HStack {
                    Button("Close", action: close)
                    if planned.completedDate == nil { PostponeButton(planned: planned, onDone: close) }
                    Spacer()
                    if store.profile.ftp != nil {
                        Button("Start Workout") { close(); app.start(w, planned: planned) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
            } else {
                Text("Workout unavailable")
                Button("Close", action: close)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
