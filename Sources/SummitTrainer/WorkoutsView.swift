import SwiftUI

struct WorkoutsView: View {
    @EnvironmentObject var store: Store
    @State private var selected: AdhocWorkout?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Workouts").font(.largeTitle.bold())
                if let ftp = store.profile.ftp {
                    Text("Ride something outside your plan. Every workout is scaled to your FTP of \(Int(ftp)) W, and you can dial it up or down before you start.")
                        .foregroundColor(.gray)
                    ForEach(AdhocWorkout.Category.allCases, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cat.rawValue).font(.title3.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                ForEach(AdhocWorkout.allWhere(cat)) { w in
                                    Button { selected = w } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Label(w.name, systemImage: w.icon).font(.headline)
                                            Text(w.blurb).font(.callout).foregroundColor(.gray)
                                                .multilineTextAlignment(.leading).lineLimit(3)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                                        .padding(12)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.17)))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    Text("Set your FTP first (take an FTP test, or enter it in Settings) so workouts can be scaled to you.")
                        .foregroundColor(.orange)
                }
            }
            .padding(24)
        }
        .sheet(item: $selected) { w in AdhocDetail(adhoc: w) { selected = nil } }
    }
}

extension AdhocWorkout {
    static func allWhere(_ c: Category) -> [AdhocWorkout] { AdhocLibrary.all.filter { $0.category == c } }
}

private struct AdhocDetail: View {
    let adhoc: AdhocWorkout
    let close: () -> Void
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @State private var option = 0
    @State private var intensity = 1.0

    private var ftp: Double { store.profile.ftp ?? 200 }
    private var workout: Workout { adhoc.build(ftp, option) }
    private var isFree: Bool { workout.segments.allSatisfy { !$0.erg } }

    var body: some View {
        let w = workout
        VStack(alignment: .leading, spacing: 12) {
            Text(adhoc.category.rawValue.uppercased()).font(.caption.bold()).foregroundColor(.gray)
            Text(w.name).font(.title.bold())
            Text(adhoc.blurb)
            if let n = w.note { Text(n).font(.callout).foregroundColor(.gray) }

            if adhoc.options.count > 1 {
                Picker(adhoc.optionTitle, selection: $option) {
                    ForEach(adhoc.options) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
            }

            if !isFree {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Intensity: \(Int((intensity * 100).rounded()))% of workout targets (effective FTP \(Int((ftp * intensity).rounded())) W)")
                        Spacer()
                        Button("Relax 85%") { intensity = 0.85 }
                        Button("Standard") { intensity = 1.0 }
                        Button("Push 110%") { intensity = 1.10 }
                    }
                    Slider(value: $intensity, in: 0.6...1.2, step: 0.01)
                }
            }

            WorkoutChart(workout: w, ftp: ftp * intensity, elapsed: -1, samples: [])
                .frame(height: 130).cornerRadius(8)

            Text(formatTime(w.totalSeconds)
                 + (isFree ? "" : " · est. TSS \(Int((w.estimatedTSS * intensity * intensity).rounded()))"))
                .font(.headline)

            HStack {
                Button("Close", action: close)
                Spacer()
                Button("Start Workout") { close(); app.start(w, intensity: intensity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { option = adhoc.defaultValue }
    }
}
