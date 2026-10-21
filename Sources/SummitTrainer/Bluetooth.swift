import Foundation
import CoreBluetooth

enum BLEUUID {
    static let ftms = CBUUID(string: "1826")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let ftmsControl = CBUUID(string: "2AD9")
    static let cps = CBUUID(string: "1818")
    static let cpsMeasurement = CBUUID(string: "2A63")
    static let hrs = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")
}

struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var isTrainer: Bool     // FTMS smart trainer (ERG capable)
    var isPower: Bool       // cycling power service (power meter / basic trainer)
    var isHR: Bool

    var kindLabel: String {
        var parts: [String] = []
        if isTrainer { parts.append("Smart trainer (FTMS)") }
        if isPower && !isTrainer { parts.append("Power meter") }
        if isHR { parts.append("Heart rate") }
        return parts.joined(separator: ", ")
    }
}

struct LiveReading {
    var power: Int?
    var hr: Int?
    var cadence: Int?
    var speed: Double?        // km/h
}

/// Handles Bluetooth LE: FTMS smart trainers (Elite Suito, Wahoo KICKR, Tacx, Saris, JetBlack...),
/// Cycling Power devices, and Heart Rate monitors. Includes a demo simulator.
final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var devices: [BLEDevice] = []
    @Published var scanning = false
    @Published var trainerName: String?
    @Published var hrName: String?
    @Published var ergReady = false
    @Published var powerOnly = false
    @Published var demoMode = false
    @Published var livePower: Int?
    @Published var liveCadence: Int?
    @Published var liveHR: Int?
    @Published var statusText = ""

    var onRememberTrainer: ((UUID) -> Void)?
    var onRememberHR: ((UUID) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var trainerPeripheral: CBPeripheral?
    private var hrPeripheral: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var wantTrainerID: UUID?
    private var wantHRID: UUID?
    private var pendingScan = false
    private var knownTrainerID: UUID?
    private var knownHRID: UUID?
    private var autoScanning = false

    // latest values with timestamps
    private var power: Int?, powerAt = Date.distantPast
    private var cadence: Int?, cadenceAt = Date.distantPast
    private var speed: Double?, speedAt = Date.distantPast
    private var trainerHR: Int?, trainerHRAt = Date.distantPast
    private var strapHR: Int?, strapHRAt = Date.distantPast
    private var lastCrank: (revs: Int, time: Int, at: Date)?

    // demo simulation
    private var simTarget = 100
    private var simHR = 80.0

    private var staleTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        staleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLive()
        }
    }

    // MARK: Public API

    func startScan() {
        guard central.state == .poweredOn else { pendingScan = true; return }
        devices.removeAll()
        scanning = true
        central.scanForPeripherals(withServices: [BLEUUID.ftms, BLEUUID.cps, BLEUUID.hrs],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        scanning = false
    }

    func connectTrainer(_ d: BLEDevice) {
        guard let p = peripherals[d.id] else { return }
        if let old = trainerPeripheral, old != p { central.cancelPeripheralConnection(old) }
        trainerPeripheral = p
        wantTrainerID = d.id
        statusText = "Connecting to \(d.name)…"
        central.connect(p, options: nil)
    }

    func connectHR(_ d: BLEDevice) {
        guard let p = peripherals[d.id] else { return }
        if let old = hrPeripheral, old != p { central.cancelPeripheralConnection(old) }
        hrPeripheral = p
        wantHRID = d.id
        central.connect(p, options: nil)
    }

    func disconnectTrainer() {
        wantTrainerID = nil
        if let p = trainerPeripheral { central.cancelPeripheralConnection(p) }
        trainerPeripheral = nil
        trainerName = nil
        ergReady = false
    }

    func disconnectHR() {
        wantHRID = nil
        if let p = hrPeripheral { central.cancelPeripheralConnection(p) }
        hrPeripheral = nil
        hrName = nil
    }

    /// Remember previously used devices and reconnect to them. Safe to call before Bluetooth is ready:
    /// the attempt is repeated when the radio powers on.
    func reconnectKnown(trainerID: String?, hrID: String?) {
        knownTrainerID = trainerID.flatMap { UUID(uuidString: $0) }
        knownHRID = hrID.flatMap { UUID(uuidString: $0) }
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard central.state == .poweredOn else { return }
        var needScan = false
        if let id = knownTrainerID, trainerPeripheral == nil {
            if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                peripherals[id] = p
                trainerPeripheral = p
                wantTrainerID = id
                statusText = "Reconnecting to saved trainer…"
                central.connect(p, options: nil)
            } else { needScan = true }
        }
        if let id = knownHRID, hrPeripheral == nil {
            if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                peripherals[id] = p
                hrPeripheral = p
                wantHRID = id
                central.connect(p, options: nil)
            } else { needScan = true }
        }
        if needScan && !scanning {
            autoScanning = true
            startScan()
        }
    }

    var hasTrainer: Bool { demoMode || trainerPeripheral != nil && trainerName != nil }

    /// Latest fresh readings (data older than 4 s is dropped).
    func snapshot() -> LiveReading {
        if demoMode { return demoReading() }
        let now = Date()
        var r = LiveReading()
        if now.timeIntervalSince(powerAt) < 4 { r.power = power }
        if now.timeIntervalSince(cadenceAt) < 4 { r.cadence = cadence }
        if now.timeIntervalSince(speedAt) < 4 { r.speed = speed }
        if now.timeIntervalSince(strapHRAt) < 4 {
            r.hr = strapHR
        } else if now.timeIntervalSince(trainerHRAt) < 4 {
            r.hr = trainerHR
        }
        return r
    }

    // MARK: Trainer control (FTMS)

    func setTargetPower(_ watts: Int) {
        simTarget = watts
        let w = Int16(max(0, min(2000, watts)))
        let u = UInt16(bitPattern: w)
        writeControl([0x05, UInt8(u & 0xFF), UInt8(u >> 8)])
    }

    /// Resistance by grade (%), used for free-ride (non-ERG) efforts such as the 20-minute test.
    func setGrade(_ percent: Double) {
        let g = UInt16(bitPattern: Int16(percent * 100))
        writeControl([0x11, 0x00, 0x00, UInt8(g & 0xFF), UInt8(g >> 8), 40, 51])
        simTarget = 220
    }

    func startWorkout() { writeControl([0x07]) }
    func pauseWorkout() { writeControl([0x08, 0x02]) }
    func stopWorkout() { writeControl([0x08, 0x01]) }

    private func writeControl(_ bytes: [UInt8]) {
        guard let cp = controlPoint, let p = trainerPeripheral else { return }
        p.writeValue(Data(bytes), for: cp, type: .withResponse)
    }

    // MARK: Central delegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        bluetoothState = c.state
        if c.state == .poweredOn && pendingScan {
            pendingScan = false
            startScan()
        }
        if c.state == .poweredOn { attemptReconnect() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"
        peripherals[p.identifier] = p
        if p.identifier == knownTrainerID && trainerPeripheral == nil {
            trainerPeripheral = p
            wantTrainerID = p.identifier
            c.connect(p, options: nil)
        }
        if p.identifier == knownHRID && hrPeripheral == nil {
            hrPeripheral = p
            wantHRID = p.identifier
            c.connect(p, options: nil)
        }
        if autoScanning {
            let trainerDone = knownTrainerID == nil || trainerPeripheral != nil
            let hrDone = knownHRID == nil || hrPeripheral != nil
            if trainerDone && hrDone { autoScanning = false; stopScan() }
        }
        let dev = BLEDevice(id: p.identifier, name: name, rssi: RSSI.intValue,
                            isTrainer: uuids.contains(BLEUUID.ftms),
                            isPower: uuids.contains(BLEUUID.cps),
                            isHR: uuids.contains(BLEUUID.hrs))
        if let i = devices.firstIndex(where: { $0.id == dev.id }) {
            devices[i] = dev
        } else {
            devices.append(dev)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        if p == trainerPeripheral {
            trainerName = p.name ?? "Trainer"
            statusText = "Connected to \(trainerName ?? "trainer")"
            onRememberTrainer?(p.identifier)
            p.discoverServices([BLEUUID.ftms, BLEUUID.cps])
        }
        if p == hrPeripheral {
            hrName = p.name ?? "HR monitor"
            onRememberHR?(p.identifier)
            p.discoverServices([BLEUUID.hrs])
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        statusText = "Connection failed: \(error?.localizedDescription ?? "unknown")"
        if p == trainerPeripheral && wantTrainerID == p.identifier || p == hrPeripheral && wantHRID == p.identifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self else { return }
                let stillWanted = (p == self.trainerPeripheral && self.wantTrainerID == p.identifier)
                    || (p == self.hrPeripheral && self.wantHRID == p.identifier)
                if stillWanted { self.central.connect(p, options: nil) }
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if p == trainerPeripheral {
            ergReady = false
            controlPoint = nil
            statusText = "Trainer disconnected. Reconnecting…"
            if wantTrainerID == p.identifier { central.connect(p, options: nil) } else { trainerName = nil }
        }
        if p == hrPeripheral {
            if wantHRID == p.identifier { central.connect(p, options: nil) } else { hrName = nil }
        }
    }

    // MARK: Peripheral delegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else { return }
        if p == trainerPeripheral {
            let hasFTMS = services.contains { $0.uuid == BLEUUID.ftms }
            powerOnly = !hasFTMS
            for s in services {
                if s.uuid == BLEUUID.ftms { p.discoverCharacteristics([BLEUUID.indoorBikeData, BLEUUID.ftmsControl], for: s) }
                if s.uuid == BLEUUID.cps && !hasFTMS { p.discoverCharacteristics([BLEUUID.cpsMeasurement], for: s) }
            }
        }
        if p == hrPeripheral {
            for s in services where s.uuid == BLEUUID.hrs {
                p.discoverCharacteristics([BLEUUID.hrMeasurement], for: s)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEUUID.indoorBikeData, BLEUUID.cpsMeasurement, BLEUUID.hrMeasurement:
                p.setNotifyValue(true, for: c)
            case BLEUUID.ftmsControl:
                controlPoint = c
                p.setNotifyValue(true, for: c)   // indications carry control responses
                // Ask for control of the trainer
                p.writeValue(Data([0x00]), for: c, type: .withResponse)
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        switch c.uuid {
        case BLEUUID.indoorBikeData: parseIndoorBike(data)
        case BLEUUID.cpsMeasurement: parseCyclingPower(data)
        case BLEUUID.hrMeasurement: parseHR(data)
        case BLEUUID.ftmsControl: parseControlResponse(data)
        default: break
        }
    }

    // MARK: Parsing

    private func parseControlResponse(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 3, b[0] == 0x80 else { return }
        let request = b[1], result = b[2]
        if request == 0x00 {
            if result == 0x01 {
                ergReady = true
                statusText = "Trainer ready (ERG control granted)"
                writeControl([0x07])
            } else {
                statusText = "Trainer refused control. Close other apps connected to it."
            }
        }
    }

    private func parseIndoorBike(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 2 else { return }
        let flags = UInt16(b[0]) | (UInt16(b[1]) << 8)
        var i = 2
        func u16() -> Int? {
            guard i + 2 <= b.count else { return nil }
            let v = Int(b[i]) | (Int(b[i + 1]) << 8)
            i += 2
            return v
        }
        var spd: Double?
        if flags & 0x0001 == 0, let v = u16() { spd = Double(v) / 100.0 }   // instantaneous speed, 0.01 km/h
        if flags & 0x0002 != 0 { i += 2 }                          // average speed
        var cad: Double?
        if flags & 0x0004 != 0, let v = u16() { cad = Double(v) / 2.0 }
        if flags & 0x0008 != 0 { i += 2 }                          // average cadence
        if flags & 0x0010 != 0 { i += 3 }                          // total distance
        if flags & 0x0020 != 0 { i += 2 }                          // resistance level
        var pw: Int?
        if flags & 0x0040 != 0, let v = u16() { pw = Int(Int16(truncatingIfNeeded: v)) }
        if flags & 0x0080 != 0 { i += 2 }                          // average power
        if flags & 0x0100 != 0 { i += 5 }                          // energy
        var hr: Int?
        if flags & 0x0200 != 0, i < b.count { hr = Int(b[i]); i += 1 }

        let now = Date()
        if let pw = pw { power = max(0, pw); powerAt = now }
        if let c = cad { cadence = Int(c.rounded()); cadenceAt = now }
        if let v = spd { speed = v; speedAt = now }
        if let h = hr, h > 0 { trainerHR = h; trainerHRAt = now }
    }

    private func parseCyclingPower(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 4 else { return }
        let flags = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let pw = Int(Int16(truncatingIfNeeded: UInt16(b[2]) | (UInt16(b[3]) << 8)))
        power = max(0, pw)
        powerAt = Date()
        var i = 4
        if flags & 0x0001 != 0 { i += 1 }       // pedal balance
        if flags & 0x0004 != 0 { i += 2 }       // accumulated torque
        if flags & 0x0010 != 0 { i += 6 }       // wheel revolution data
        if flags & 0x0020 != 0, i + 4 <= b.count {
            let revs = Int(b[i]) | (Int(b[i + 1]) << 8)
            let t = Int(b[i + 2]) | (Int(b[i + 3]) << 8)
            let now = Date()
            if let last = lastCrank {
                let dRev = (revs - last.revs) & 0xFFFF
                let dT = (t - last.time) & 0xFFFF
                if dT > 0 {
                    cadence = Int((Double(dRev) / (Double(dT) / 1024.0) * 60.0).rounded())
                    cadenceAt = now
                    lastCrank = (revs, t, now)
                } else if now.timeIntervalSince(last.at) > 2 {
                    cadence = 0
                    cadenceAt = now
                }
            } else {
                lastCrank = (revs, t, now)
            }
        }
    }

    private func parseHR(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 2 else { return }
        let hr: Int
        if b[0] & 0x01 == 0 {
            hr = Int(b[1])
        } else if b.count >= 3 {
            hr = Int(b[1]) | (Int(b[2]) << 8)
        } else { return }
        if hr > 0 { strapHR = hr; strapHRAt = Date() }
    }

    // MARK: Live display & demo

    private func refreshLive() {
        let s = snapshot()
        livePower = s.power
        liveCadence = s.cadence
        liveHR = s.hr
    }

    private func demoReading() -> LiveReading {
        let noise = Double.random(in: -0.03...0.03)
        let p = max(0, Int(Double(simTarget) * (1.0 + noise)))
        let hrTarget = 65.0 + Double(p) * 0.45
        simHR += (hrTarget - simHR) * 0.04
        return LiveReading(power: p, hr: Int(simHR), cadence: 88 + Int.random(in: -4...4))
    }
}
