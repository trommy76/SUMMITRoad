import SwiftUI

extension Store {
    /// Moves a planned workout `days` later. With `laterToo`, every unfinished workout on or after it moves by the same
    /// amount, so the rest of the plan keeps its shape instead of piling up on the days after.
    func postpone(_ id: UUID, days: Int, laterToo: Bool) {
        guard days > 0, var p = plan, let i = p.workouts.firstIndex(where: { $0.id == id }) else { return }
        let cal = Calendar.current
        let from = p.workouts[i].date
        for j in p.workouts.indices {
            let w = p.workouts[j]
            guard w.completedDate == nil, j == i || (laterToo && w.date >= from) else { continue }
            p.workouts[j].date = cal.date(byAdding: .day, value: days, to: w.date) ?? w.date
        }
        // Keep the list in date order (the "next workout" logic reads it in order).
        p.workouts = p.workouts.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map { $0.element }
        plan = p
    }

    /// Unfinished workouts after this one, which "this and all later" would move too.
    func laterWorkoutCount(after id: UUID) -> Int {
        guard let p = plan, let w = p.workouts.first(where: { $0.id == id }) else { return 0 }
        return p.workouts.filter { $0.id != id && $0.completedDate == nil && $0.date >= w.date }.count
    }
}

private let postponeDay: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f
}()

/// "Postpone…" button for a planned workout: pick how many days, and whether the rest of the plan moves with it.
struct PostponeButton: View {
    let planned: PlannedWorkout
    var onDone: () -> Void = {}
    @State private var show = false

    var body: some View {
        Button("Postpone…") { show = true }
            .popover(isPresented: $show) {
                PostponeForm(planned: planned) { show = false; onDone() }
            }
    }
}

private struct PostponeForm: View {
    let planned: PlannedWorkout
    let done: () -> Void
    @EnvironmentObject var store: Store
    @State private var days: Int
    @State private var laterToo = true

    init(planned: PlannedWorkout, done: @escaping () -> Void) {
        self.planned = planned
        self.done = done
        // A missed workout starts at "today"; anything else at tomorrow's slot.
        let cal = Calendar.current
        let late = cal.dateComponents([.day], from: planned.date, to: cal.startOfDay(for: Date())).day ?? 0
        _days = State(initialValue: max(1, late))
    }

    private var newDate: Date { Calendar.current.date(byAdding: .day, value: days, to: planned.date) ?? planned.date }
    private var later: Int { store.laterWorkoutCount(after: planned.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Postpone workout").font(.headline)
            Stepper("Move by \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...60)
            Text("\(postponeDay.string(from: planned.date))  →  \(postponeDay.string(from: newDate))").foregroundColor(.gray)
            Picker("", selection: $laterToo) {
                Text("This workout only").tag(false)
                Text("This and all later workouts").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if laterToo {
                Text(later == 0 ? "There are no later workouts." : "\(later) later workout\(later == 1 ? "" : "s") will move by the same amount.")
                    .font(.caption).foregroundColor(.gray)
            }
            HStack {
                Button("Cancel") { done() }
                Spacer()
                Button("Postpone") { store.postpone(planned.id, days: days, laterToo: laterToo); done() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 330)
    }
}
