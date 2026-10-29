# SummitRoad (macOS)

A SwiftUI indoor-cycling trainer app: smart-trainer ERG control, heart-rate monitors, FTP tests, an adaptive training plan, live coaching, scoring and Strava upload.

## Screenshots

All screenshots use demo data.

### The Mac app

| | |
|---|---|
| **Calendar**: planned workouts with a profile preview, completed rides with their score, and weekly hours/TSS | **Today**: your FTP and the next workout |
| ![Calendar](docs/screenshots/app-calendar.png) | ![Today](docs/screenshots/app-today.png) |
| **Training Plan**: Base, Build and Specialty weeks that adapt to how you ride | **Workouts**: GPX routes, plus ad-hoc workouts scaled to your FTP with drills and an intensity override |
| ![Training Plan](docs/screenshots/app-plan.png) | ![Workouts](docs/screenshots/app-workouts.png) |

**The ride screen**: power, interval time and heart rate on top; target, workout time and cadence below; interval stats and the workout profile with your live trace.

![Ride screen](docs/screenshots/app-ride.png)

**Routes** (see [Routes (GPX)](#routes-gpx)): pick a section of a GPX route to fit the time you have, then ride it in simulation mode. The elevation profile is coloured by gradient, with a bike at your position.

| | |
|---|---|
| ![Route picker](docs/screenshots/app-route-picker.png) | ![Route ride](docs/screenshots/app-route-ride.png) |

(The routes in these screenshots are made-up demo routes.)

**Ride report**: training score, coach feedback and a chart you can hover for the values at each point; send the .FIT file to Strava or Garmin.

![Ride report](docs/screenshots/app-ride-report.png)

**Settings**: FTP, Strava, the optional home server, updates and data.

![Settings](docs/screenshots/app-settings.png)

### The home server website (optional, see [server/README.md](server/README.md))

A small Docker container keeps your rides, FTP history, plan and settings on your own network, syncs them between your Macs and shows them in a browser.

| | |
|---|---|
| **Sign-in**, with optional two-factor | **Dashboard**: totals, FTP history, weekly TSS and every ride |
| ![Sign-in](docs/screenshots/web-login.png) | ![Dashboard](docs/screenshots/web-dashboard.png) |

**Ride detail**: hover the chart for power, target, heart rate, cadence and speed.

![Ride detail](docs/screenshots/web-ride-detail.png)

**Training plan** (read-only, from your Mac) with a version history you can restore from:

![Training plan](docs/screenshots/web-plan.png)

![Plan version history](docs/screenshots/web-plan-history.png)

**Settings**: password, two-factor, app passwords for the Mac app, users (admin) and the activity log.

![Settings](docs/screenshots/web-settings.png)

![Activity log](docs/screenshots/web-activity-log.png)

## Build & run

Requirements: macOS 13+, Xcode (or Xcode command-line tools).

```bash
cd SummitTrainer      # the project folder
chmod +x build_app.sh
./build_app.sh        # builds build/SummitRoad.app (and SummitRoad.zip) and opens it
```

Or open `Package.swift` in Xcode and press Run. If running from Xcode, Bluetooth permission is attached to Xcode's process; use `build_app.sh` for the packaged app (its Info.plist has the Bluetooth usage string).

## First ride

1. **Devices** > Scan. Elite Suito shows as "SUITO" (pedal to wake it; close Zwift/Elite apps first). Click **Use as Trainer**. Pair a Bluetooth HR strap with **Use as HR Monitor**. No hardware? Turn on **Demo mode**.
2. **FTP Test** > Ramp Test (about 20 min) or 20-Minute Test. FTP = 75% of best 1-min power (ramp) or 95% of the 20-min average. Click **Use This FTP** in the report.
3. **Training Plan** > Build Plan. Questions: goal, experience, hours/week, available days, longest ride, plan length, recovery/stress. You get an 8/10/12-week Base > Build > Specialty plan with a recovery week every 4th week and FTP retests at block starts and the final week (per the TrainerRoad article: assess every 4-6 weeks).
4. **Today** > Start Workout.

## Trainer support

- **FTMS smart trainers** (Elite Suito, Wahoo KICKR/Core, Tacx, Saris, JetBlack, most others): ERG target power, free-ride resistance.
- **Cycling Power devices** (power meters, basic power-only trainers): live power and cadence, no ERG. Match the targets manually.
- **Heart-rate**: any standard BLE HR strap/armband.

## Ride screen

Power / Interval time / Heart rate, Target / Workout time / Cadence, workout profile with your live power trace, interval stats (INT POW/HR/CAD, TSS, kJ, NP, AVG POW), coaching banner (interval starts, halfway, 1 min / 30 s / 10 s, 5-4-3-2-1 countdown, cadence and HR nudges, optional spoken cues). Space = pause. ±5% intensity, skip interval, end.

## Workouts outside your plan

The **Workouts** tab has ad-hoc sessions that are scaled to your FTP and don't touch your plan: easy spins, endurance rides, tempo, sweet spot, threshold, over-unders, VO2 and 30/30s, plus drills (spin-ups, cadence ladder, one-leg drills, low-cadence strength) and a free ride. Before you start you can scale the whole session between 60% and 120% of its targets ("relax" or "push"). **Start Workout** waits until you actually start pedalling before the clock and the trainer's resistance begin (switch this off in Settings).

## Routes (GPX)

Ride any GPX route in **simulation mode**: instead of holding a power target (ERG), the trainer's resistance follows the road's gradient and you choose the effort.

1. **Workouts > Routes > Import GPX…** and give the route a name. The GPX needs elevation data (recorded rides exported from Strava or Garmin have it). The file is copied into the app's data folder on your Mac (`~/Library/Application Support/SummitTrainer/routes`) and is never uploaded or synced.
2. Open the route, then use the **Start/Finish sliders** to choose a section, or **Fit to 60 / 75 / 90 min** to pick a finish point for the time you have. The estimate comes from your power at the chosen effort (Easy 55%, Endurance 65%, Tempo 80%, Hard 95% of FTP), the gradient and your weight.
3. Set **Rider + bike weight** (Settings > Athlete, default 80 kg). It is used to work out your speed and progress along the route from your power.
4. **Start Ride.** The ride screen shows the colour-coded elevation profile (blue flat, then green, yellow, orange and red as it gets steeper) with a bike at your position and the part you've ridden dimmed. The six big numbers are power, **speed** (with your average), heart rate, grade (with elevation), distance left and cadence; a strip below shows elapsed time, distance ridden, average speed and climbing so far. The ride ends at the finish.

Gradients are smoothed over about 160 m and limited to -10% to +15%, so the resistance changes gradually. Route rides have no training score.

**Uploading:** a route ride is saved as a **virtual ride** with the route's GPS track, speed, distance, altitude, gradient and total climbing, so Strava and Garmin can draw the map and the elevation. That means the roads of your route end up on those sites, so check Strava's privacy zone first if a route starts near home.

Resistance depends on how your trainer turns a gradient into feel, which varies between trainers. If climbs feel too easy or too hard, please say so.

## Training score (0-100)

Completion 35%, power accuracy 35% (±5% of target = full marks), cadence in band 15%, HR in expected zone 15%. Missing sensors are left out and the weights are rescaled.

After each ride you get coach feedback (power vs target, fade, cadence, HR zone, cardiac drift) and a plan verdict: scores of 88+ raise upcoming difficulty, below 72 ease it, and repeated poor scores or very high scores recommend an FTP retest.

## Strava

1. strava.com/settings/api > create an app. Set **Authorization Callback Domain** to `localhost`.
2. Settings > paste Client ID and Secret > Connect to Strava (approve in the browser).
3. Rides are saved as `.FIT` and can be uploaded from the ride report, or automatically after each ride.

Data (profile, plan, rides, .FIT files) is in `~/Library/Application Support/SummitTrainer`.
