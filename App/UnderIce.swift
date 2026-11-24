import Foundation
import Combine

func tr(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func label(_ key: String, _ values: CVarArg...) -> String {
    String(format: tr(key), locale: Locale.current, arguments: values)
}

func watchTime(_ minute: Int) -> String {
    String(format: "%02d:%02d", (6 + minute / 60) % 24, minute % 60)
}

struct Profile: Codable, Identifiable {
    let id: String
    let notes: [Double]
    let beats: [Double]
    let loop: Double
    let depth: Int
    let lure: Int

    var name: String { tr(id) }
    var pattern: String { tr("rhythm." + id) }
}

struct Expedition: Codable, Identifiable {
    let id: String
    let lake: Int
    let source: String
    let tune: Int
    let route: [Int]
    let noise: Double
    var echo: Int?
    var rival: String?
    var fragment: String?
    var timed: Bool?
    var survey: Int?

    var title: String { survey == nil ? tr(id) : tr("Free survey") }
    var moving: Bool { route.count > 1 }
}

struct Campaign: Codable {
    let profiles: [Profile]
    let levels: [Expedition]

    var fish: [Profile] {
        profiles.filter { !["echo", "beacon"].contains($0.id) && !fragmentIDs.contains($0.id) }
    }

    func profile(_ id: String) -> Profile {
        profiles.first { $0.id == id }!
    }
}

let depthKeys = ["Shallows", "Deep water"]
let lureKeys = ["Small jig", "Copper spoon", "Soft grub"]
let lureIcons = ["circle.hexagongrid.fill", "capsule.rotate.90.fill", "waveform.path"]
let lakeKeys = ["Glass Bay", "Reed Flood", "Old Pier"]
let fragmentIDs = ["clock", "pair", "tail"]

let lakeHoles: [[CGPoint]] = [
    [.init(x: 0.21, y: 0.65), .init(x: 0.53, y: 0.37), .init(x: 0.80, y: 0.69)],
    [.init(x: 0.18, y: 0.66), .init(x: 0.39, y: 0.30), .init(x: 0.65, y: 0.43), .init(x: 0.83, y: 0.71)],
    [.init(x: 0.16, y: 0.64), .init(x: 0.32, y: 0.30), .init(x: 0.53, y: 0.57), .init(x: 0.72, y: 0.29), .init(x: 0.85, y: 0.63)]
]

struct Reading: Codable, Identifiable {
    var id: Int
    var hole: Int
    var depth: Int
    var minute: Int
    var tune: Int
    var sources: [String]
    var strength: Double
    var clarity: Double

    var time: String { watchTime(minute) }
}

struct CatchNote: Codable, Identifiable {
    var id: String { task }
    var task: String
    var fish: String
    var lake: Int
    var hole: Int
    var minute: Int
}

struct Trip: Codable {
    var id: String
    var hole: Int?
    var tune = 1
    var depth = 0
    var lure = 0
    var minute = 0
    var serial = 0
    var pins: [Reading] = []
    var phase = "listen"
    var feedback = ""
    var strokes = 0
    var surveyRound: Int?
    var fight: FightMemory?
}

struct Logbook: Codable {
    var trip = Trip(id: "double")
    var completed: [String] = []
    var catches: [CatchNote] = []
    var fragments: [String] = []
    var sequence: [String] = []
    var muted = false
}

final class LakeGame: ObservableObject {
    let campaign: Campaign
    private let defaults: UserDefaults
    private let saveKey = "expedition.v1"
    @Published var book = Logbook() {
        didSet {
            if let data = try? JSONEncoder().encode(book) { defaults.set(data, forKey: saveKey) }
        }
    }

    init(defaults: UserDefaults, campaign: Campaign? = nil) {
        self.defaults = defaults
        if let campaign {
            self.campaign = campaign
        } else {
            let url = Bundle.main.url(forResource: "Campaign", withExtension: "json")!
            self.campaign = try! JSONDecoder().decode(Campaign.self, from: Data(contentsOf: url))
        }
        if let data = defaults.data(forKey: saveKey),
           var saved = try? JSONDecoder().decode(Logbook.self, from: data) {
            if saved.trip.phase == "fight", saved.trip.fight == nil {
                let lake = self.campaign.levels.first { $0.id == saved.trip.id }?.lake
                    ?? saved.trip.id.last?.wholeNumberValue ?? 0
                let fraction = Double(saved.trip.strokes) / (lake == 0 ? 4.0 : 6.0)
                saved.trip.fight = FightMemory(winding: clamp(fraction) * (lake == 0 ? 0.88 : 0.96),
                                               load: saved.trip.strokes.isMultiple(of: 2) ? 0.32 : 0.80)
            }
            book = saved
        }
    }

    var trip: Trip { book.trip }
    var finalised: Bool { book.completed.contains("broadcast") }
    var aligned: Bool { book.sequence == fragmentIDs }

    var level: Expedition {
        if let fixed = campaign.levels.first(where: { $0.id == trip.id }) { return fixed }
        let lake = Int(trip.id.last?.wholeNumberValue ?? 0)
        let round = trip.surveyRound ?? 0
        let index = (round + lake * 3) % campaign.fish.count
        let fish = campaign.fish[index]
        let count = lakeHoles[lake].count
        let origin = (round + lake + 2) % count
        let route = (0..<count).map { (origin + $0) % count }
        return Expedition(id: trip.id, lake: lake, source: fish.id, tune: index % 5,
                          route: route,
                          noise: 0.16 + Double(lake) * 0.08, survey: lake)
    }

    func available(_ index: Int) -> Bool {
        index == 0 || book.completed.contains(campaign.levels[index - 1].id)
    }

    func open(_ id: String) {
        guard id != trip.id else { return }
        if id.hasPrefix("survey-") {
            let round = book.catches.filter { $0.task.hasPrefix(id + "-") }.count
            book.trip = Trip(id: id, surveyRound: round)
        } else {
            book.trip = Trip(id: id)
        }
    }

    func select(_ hole: Int) {
        guard trip.phase == "listen" else { return }
        book.trip.hole = hole
        book.trip.feedback = ""
    }

    func tune(_ channel: Int) {
        guard trip.phase == "listen" else { return }
        book.trip.tune = min(4, max(0, channel))
    }

    func setDepth(_ depth: Int) { book.trip.depth = depth }
    func setLure(_ lure: Int) { book.trip.lure = lure }

    func waitMinute() {
        guard trip.phase == "listen" || trip.phase == "rig" else { return }
        book.trip.minute += 1
        book.trip.feedback = "Watch advanced. The ice has gone quiet again."
    }

    func target(_ minute: Int) -> Int {
        level.route[minute % level.route.count]
    }

    func distanceStrength(hole: Int, origin: Int) -> Double {
        let holes = lakeHoles[level.lake]
        let x = holes[hole].x - holes[origin].x
        let y = holes[hole].y - holes[origin].y
        return max(0.12, 0.94 - hypot(x, y) * 1.06)
    }

    var live: Reading? {
        guard let hole = trip.hole else { return nil }
        let fish = campaign.profile(level.source)
        let error = abs(trip.tune - level.tune)
        var strength = distanceStrength(hole: hole, origin: target(trip.minute))
        var sources = [fish.id]
        if let echo = level.echo, hole == echo, fish.depth != trip.depth {
            sources = ["echo"]
            strength = 0.79
        } else {
            if fish.depth != trip.depth { strength *= 0.68 }
            if let rival = level.rival, campaign.profile(rival).depth == trip.depth {
                sources.append(rival)
                strength = max(strength, 0.55)
            }
        }
        return Reading(id: trip.serial, hole: hole, depth: trip.depth, minute: trip.minute,
                       tune: trip.tune, sources: sources, strength: strength,
                       clarity: max(0.13, 0.97 - Double(error) * 0.26 - level.noise * 0.25))
    }

    func pin() {
        guard let live, trip.phase == "listen" else { return }
        var updated = trip
        updated.pins = Array((updated.pins + [live]).suffix(3))
        updated.serial += 1
        updated.feedback = ""
        book.trip = updated
    }

    var timeEvidence: Bool {
        let strong = trip.pins.filter {
            $0.sources.contains(level.source) && $0.clarity > 0.8 &&
            $0.hole == target($0.minute)
        }
        return Set(strong.map(\.minute)).count >= 2 && Set(strong.map(\.hole)).count >= 2
    }

    func rig() {
        guard trip.hole != nil, trip.phase == "listen" else { return }
        book.trip.phase = "rig"
        book.trip.feedback = ""
    }

    func listen() {
        guard trip.phase == "rig" else { return }
        book.trip.phase = "listen"
        book.trip.feedback = ""
    }

    func drop() {
        guard trip.phase == "rig", let hole = trip.hole else { return }
        let fish = campaign.profile(level.source)
        let arrival = trip.minute + (level.moving ? 1 : 0)
        let arrivalHole = target(arrival)
        if level.id == "broadcast", !aligned {
            book.trip.feedback = "Join the three phrases in your journal first."
            return
        }
        if level.id == "broadcast" {
            let deepPins = trip.pins.filter {
                $0.sources == ["beacon"] && $0.depth == fish.depth && $0.tune == level.tune
            }
            if !deepPins.contains(where: { $0.hole == arrivalHole }) || Set(deepPins.map(\.hole)).count < 2 {
                book.trip.feedback = "Pin the beacon at two holes on channel 4 in deep water."
                return
            }
        }
        if level.timed == true, !timeEvidence {
            book.trip.feedback = "Pin strong readings at two different stops before predicting the next."
            return
        }

        var updated = trip
        if hole != arrivalHole {
            updated.feedback = "Weak echo. The source passed another hole."
        } else if trip.depth != fish.depth {
            updated.feedback = trip.depth == 0
                ? "Pass below the hook. Try deep water."
                : "Pass above the hook. Try the shallows."
        } else if level.id != "broadcast", trip.lure != fish.lure {
            updated.feedback = "Interest without a bite. Check the lure in the field guide."
        } else {
            updated.phase = "bite"
            updated.feedback = ""
            updated.strokes = 0
        }
        if updated.phase == "rig", level.moving { updated.minute = arrival }
        book.trip = updated
    }

    func strike() {
        guard trip.phase == "bite" else { return }
        var updated = trip
        updated.phase = "fight"
        updated.fight = FightMemory()
        book.trip = updated
    }

    func rememberFight(_ memory: FightMemory) {
        guard trip.phase == "fight" else { return }
        book.trip.fight = memory
    }

    func finishFight(landed: Bool) {
        guard trip.phase == "fight" else { return }
        var updated = trip
        updated.fight = nil
        if landed {
            updated.phase = "landed"
        } else {
            updated.phase = "rig"
            updated.feedback = "The line pulled tight. The source slipped free."
            if level.moving { updated.minute += 1 }
        }
        book.trip = updated
    }

    func fileCatch() {
        guard trip.phase == "landed", let hole = trip.hole else { return }
        var updated = book
        let task = level
        if let lake = task.survey {
            let round = trip.surveyRound ?? 0
            let id = task.id + "-" + String(round)
            if !updated.catches.contains(where: { $0.id == id }) {
                updated.catches.append(CatchNote(task: id, fish: task.source, lake: lake,
                                                hole: hole, minute: trip.minute))
            }
            updated.trip = Trip(id: task.id, surveyRound: round + 1)
        } else {
            if !updated.completed.contains(task.id) {
                updated.completed.append(task.id)
                if task.id != "broadcast" {
                    updated.catches.append(CatchNote(task: task.id, fish: task.source, lake: task.lake,
                                                    hole: hole, minute: trip.minute))
                }
                if let fragment = task.fragment, !updated.fragments.contains(fragment) {
                    updated.fragments.append(fragment)
                }
            }
            updated.trip.phase = "filed"
        }
        book = updated
    }

    func addPhrase(_ id: String) {
        guard book.fragments.contains(id), !book.sequence.contains(id) else { return }
        book.sequence.append(id)
    }
}

// A light spring follows the fish's run. Only the winding and load are persisted.
struct FightMemory: Codable {
    var winding = 0.0
    var load = 0.32
}

enum LineHand {
    case none, wind, ease
}

func blend(_ a: Double, _ b: Double, _ amount: Double) -> Double {
    a + (b - a) * amount
}

func clamp(_ n: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
    min(high, max(low, n))
}

func smooth(_ n: Double) -> Double {
    let t = clamp(n)
    return t * t * (3 - 2 * t)
}

struct FightMotion {
    var memory = FightMemory()
    var x = 0.55
    var y = 0.64
    var vx = 0.0
    var vy = 0.0
    var heading = 0.0
    var time = 0.0
    var spool = 0.0
    var spoolSpeed = 0.0
    var rodLoad = 0.32
    var overload = 0.0
    var lift = 0.0
    var failed = false
    var arrived = false
    var liftX = 0.55
    var liftY = 0.64

    mutating func advance(_ dt: Double, hand: LineHand, depth: Int, lake: Int, anchored: Bool = false) {
        time += dt
        let goal = lake == 0 ? 0.88 : 0.96
        let targetSpeed = hand == .wind ? 13.0 : hand == .ease ? -5.5 : 0
        spoolSpeed += (targetSpeed - spoolSpeed) * min(1, dt * 10)
        spool += spoolSpeed * dt
        if arrived {
            lift += dt
            rodLoad += (0.20 - rodLoad) * dt * 4
            return
        }

        let reach = clamp(memory.winding / goal)
        let turn = time * (2.15 + Double(lake) * 0.18)
        let baseDepth = depth == 0 ? 0.58 : 0.82
        let sway = anchored ? 0.034 : 0.21 - 0.145 * reach
        let surge = anchored ? 0.019 : 0.075
        let nextX = 0.49 + sway * sin(turn + 0.30)
        let nextY = blend(baseDepth, 0.25, reach) + surge * cos(turn * 1.24)
        vx += ((nextX - x) * 14 - vx * 4.6) * dt
        vy += ((nextY - y) * 16 - vy * 4.8) * dt
        x += vx * dt
        y += vy * dt
        if hypot(vx, vy) > 0.025 {
            let desired = atan2(vy * 1.4, vx)
            let change = atan2(sin(desired - heading), cos(desired - heading))
            heading += change * min(1, dt * 7)
        }
        let distance = hypot((x - 0.48) * 0.77, y)
        let outward = ((x - 0.48) * vx + y * vy) / max(0.10, distance)
        let paidLine = blend(baseDepth + 0.035, 0.26, reach)
        let stretch = max(0, distance - paidLine)
        let fishPull = clamp(0.28 + stretch * 1.55 + max(0, outward) * 0.95, 0.25, 0.63)
        switch hand {
        case .wind:
            memory.winding += dt * (lake == 0 ? 0.44 : 0.39)
            memory.load += (fishPull + 0.79 - memory.load) * dt * 2.0
        case .ease:
            memory.winding = max(0, memory.winding - dt * 0.035)
            memory.load += (fishPull * 0.44 - memory.load) * dt * 5.1
        case .none:
            memory.load += (fishPull - memory.load) * dt * 0.92
        }
        memory.load = clamp(memory.load, 0.08, 1.07)
        rodLoad += (memory.load - rodLoad) * dt * 8
        if memory.load > 0.92 {
            overload += dt
        } else {
            overload = max(0, overload - dt * 2.3)
        }
        if overload > 0.59 {
            failed = true
        } else if memory.winding >= goal {
            arrived = true
            liftX = x
            liftY = y
        }
    }
}

struct Pulse: Equatable {
    var time: Double
    var pitch: Double
    var weight: Double
}

struct Signal: Equatable {
    var pulses: [Pulse]
    var duration: Double
    var strength: Double
    var clarity: Double
    var noise: Double

    static func clean(_ profile: Profile) -> Signal {
        Signal(pulses: zip(profile.beats, profile.notes).map { Pulse(time: $0, pitch: $1, weight: 1) },
               duration: profile.loop, strength: 0.84, clarity: 1, noise: 0)
    }

    static func reading(_ row: Reading, _ campaign: Campaign, noise: Double) -> Signal {
        var signal = clean(campaign.profile(row.sources[0]))
        if row.sources.count > 1 {
            let rival = clean(campaign.profile(row.sources[1]))
            signal.pulses += rival.pulses.map {
                Pulse(time: $0.time + 0.14, pitch: $0.pitch, weight: 0.58)
            }
            let end = signal.pulses.map(\.time).max() ?? 0
            signal.duration = max(signal.duration, end + 0.22)
        }
        signal.strength = row.strength
        signal.clarity = row.clarity
        signal.noise = noise
        return signal
    }

    func envelope(_ time: Double, _ pulse: Pulse) -> Double {
        let distance = time - pulse.time
        guard distance >= 0, distance <= 0.098 else { return 0 }
        return min(1, distance / 0.012) * (1 - distance / 0.098) * pulse.weight * strength
    }

    func amplitude(_ time: Double) -> Double {
        pulses.map { envelope(time, $0) }.max() ?? 0
    }

    func wav() -> Data {
        wavePCM(duration) { t, noiseSample in
            var value = noiseSample * noise * (1 - clarity * 0.72) * 0.22
            for pulse in pulses {
                let env = envelope(t, pulse)
                if env > 0 {
                    let angle = (t - pulse.time) * pulse.pitch * 2 * .pi
                    value += (sin(angle) * clarity + sin(angle * 1.61) * (1 - clarity) * 0.6) * env * 0.62
                }
            }
            return value
        }
    }
}

enum WaterCue: String, CaseIterable {
    case probe, enter, crank, release, strike, snap, splash

    func wav() -> Data {
        let duration: Double
        switch self {
        case .probe: duration = 0.25
        case .enter: duration = 0.56
        case .crank: duration = 0.31
        case .release: duration = 0.32
        case .strike: duration = 0.24
        case .snap: duration = 0.20
        case .splash: duration = 0.89
        }
        var filtered = 0.0
        return wavePCM(duration) { time, noise in
            filtered += (noise - filtered) * 0.15
            let envelope = min(1, time * 270) * (1 - time / duration)
            let value: Double
            switch self {
            case .probe:
                value = 0.17 * sin(2 * .pi * (360 * time - 300 * time * time)) * exp(-time * 14)
            case .enter, .splash:
                let heavy = self == .splash ? 1.0 : 0.62
                let bubbles = max(0, sin(2 * .pi * (14 * time - 5 * time * time)))
                value = heavy * (filtered * 0.59 + sin(2 * .pi * (136 * time - 51 * time * time)) * 0.23 * bubbles)
            case .crank, .release:
                let rate = self == .crank ? 23.0 : 13.0
                let tooth = pow(max(0, sin(time * rate * 2 * .pi)), 14)
                value = (noise * 0.30 + sin(time * 2 * .pi * 940) * 0.14) * tooth
            case .strike, .snap:
                value = (noise * 0.24 + sin(2 * .pi * (204 * time - 270 * time * time)) * 0.35) * exp(-time * 18)
            }
            return value * envelope
        }
    }
}

func wavePCM(_ duration: Double, sampleValue: (Double, Double) -> Double) -> Data {
    let rate = 22_050
    let count = Int(duration * Double(rate))
    var file = Data()
    func word(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { file.append(contentsOf: $0) }
    }
    func long(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { file.append(contentsOf: $0) }
    }
    file.append(contentsOf: "RIFF".utf8)
    long(UInt32(36 + count * 2))
    file.append(contentsOf: "WAVEfmt ".utf8)
    long(16)
    word(1)
    word(1)
    long(UInt32(rate))
    long(UInt32(rate * 2))
    word(2)
    word(16)
    file.append(contentsOf: "data".utf8)
    long(UInt32(count * 2))
    var random: UInt32 = 1083
    for sample in 0..<count {
        let time = Double(sample) / Double(rate)
        random = 1_664_525 &* random &+ 1_013_904_223
        let noise = Double(random >> 16) / 32_768 - 1
        let value = clamp(sampleValue(time, noise), -1, 1)
        word(UInt16(bitPattern: Int16(value * 30_000)))
    }
    return file
}
