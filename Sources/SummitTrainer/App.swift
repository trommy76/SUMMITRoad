import SwiftUI
import AppKit

@main
struct SummitTrainerApp: App {
    @StateObject private var app = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("SummitRoad") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(app.ble)
                .environmentObject(app.strava)
                .environmentObject(app.updater)
                .environmentObject(app.sync)
                .frame(minWidth: 1000, minHeight: 720)
                .preferredColorScheme(.dark)
        }
    }
}

let brandPurple = Color(red: 0.62, green: 0.32, blue: 0.95)

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let s = app.session {
            RideView(s: s)
        } else if let r = app.review {
            RideReportView(rideID: r.id, fallback: r, isReview: true)
        } else {
            MainView()
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case calendar = "Calendar", today = "Today", plan = "Training Plan", workouts = "Workouts", ftp = "FTP Test", levels = "Levels", history = "History", devices = "Devices", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .today: return "bolt.fill"
        case .plan: return "list.bullet.rectangle"
        case .workouts: return "figure.indoor.cycle"
        case .ftp: return "gauge.high"
        case .levels: return "chart.bar.fill"
        case .history: return "clock.arrow.circlepath"
        case .devices: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

extension AppTab {
    static let mainTabs: [AppTab] = [.calendar, .today, .plan, .workouts, .ftp, .levels, .history]
    static let footerTabs: [AppTab] = [.devices, .settings]
}

struct MainView: View {
    @State var tab: AppTab = .calendar
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var sync: SyncClient

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("SUMMIT").font(.system(size: 22, weight: .heavy)).italic().foregroundColor(brandPurple)
                    Text("ROAD").font(.system(size: 22, weight: .light)).italic()
                }
                .padding(.horizontal, 20).padding(.vertical, 22)
                Divider()
                ForEach(AppTab.mainTabs) { navRow($0, big: true) }
                Spacer()
                Divider()
                ForEach(AppTab.footerTabs) { navRow($0, big: false) }
                    .padding(.bottom, 2)
                if sync.planConflict {
                    Button { tab = .settings } label: {
                        Label("Plan conflict: tap to resolve", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold()).foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20).padding(.top, 8)
                }
                if let u = updater.available {
                    Button { tab = .settings } label: {
                        Label("Update available: v\(u.version)", systemImage: "arrow.down.circle.fill")
                            .font(.caption.bold()).foregroundColor(brandPurple)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20).padding(.top, 8)
                }
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.caption2).foregroundColor(.gray)
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .background(Color(white: 0.11))
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch tab {
            case .calendar: CalendarView()
            case .today: TodayView(tab: $tab)
            case .plan: PlanView()
            case .workouts: WorkoutsView()
            case .ftp: FTPTestView()
            case .levels: LevelsView()
            case .history: HistoryView()
            case .devices: DevicesView()
            case .settings: SettingsView()
            }
        }
    }
}

extension MainView {
    func navRow(_ t: AppTab, big: Bool) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 0) {
                Rectangle().fill(tab == t ? brandPurple : Color.clear).frame(width: 4)
                Label(t.rawValue, systemImage: t.icon)
                    .font(.system(size: big ? 16 : 13, weight: big ? .semibold : .regular))
                    .foregroundColor(big || tab == t ? .primary : .gray)
                    .padding(.leading, 16)
                Spacer()
            }
            .frame(height: big ? 54 : 38)
            .background(tab == t ? Color(white: 0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension SegmentKind {
    var color: Color {
        switch self {
        case .warmup, .cooldown, .recovery: return Color(red: 0.42, green: 0.55, blue: 0.72)
        case .endurance: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .tempo: return Color(red: 0.25, green: 0.72, blue: 0.55)
        case .sweetSpot: return Color(red: 0.85, green: 0.75, blue: 0.20)
        case .threshold: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .vo2: return Color(red: 0.90, green: 0.25, blue: 0.25)
        case .anaerobic: return Color(red: 0.65, green: 0.30, blue: 0.85)
        case .test: return Color(red: 0.90, green: 0.35, blue: 0.60)
        case .drill: return Color(red: 0.30, green: 0.70, blue: 0.80)
        }
    }
}
