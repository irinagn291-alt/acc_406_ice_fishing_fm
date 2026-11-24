import AVFoundation
import SwiftUI

final class LakeRadio: ObservableObject {
    @Published private(set) var signal: Signal?
    private var player: AVAudioPlayer?
    private var effects: [AVAudioPlayer] = []
    private var cueData: [WaterCue: Data] = [:]
    private var active = false
    private var muted = false
    @Published private(set) var interrupted = false
    private var observer: NSObjectProtocol?
    private var start: TimeInterval?
    private var elapsed: TimeInterval = 0

    init() {
        #if !targetEnvironment(simulator)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        #endif
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                            object: nil, queue: .main) { [weak self] message in
            guard let raw = message.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let event = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if event == .began {
                self?.interrupted = true
                self?.pause()
            } else {
                self?.interrupted = false
                self?.resume()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var played: TimeInterval {
        elapsed + (start.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }

    var phase: Double {
        guard let signal else { return 0 }
        if let player, player.isPlaying { return player.currentTime }
        return played.truncatingRemainder(dividingBy: signal.duration)
    }

    func play(_ next: Signal?) {
        guard next != signal else { return }
        stopLoop()
        player = nil
        start = nil
        elapsed = 0
        signal = next
        resume()
    }

    func setMuted(_ value: Bool) {
        guard value != muted else { return }
        pause()
        muted = value
        resume()
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value { resume() } else { pause() }
    }

    private func pause() {
        let time = phase
        elapsed = played
        if let signal {
            elapsed = (elapsed / signal.duration).rounded(.down) * signal.duration + time
        }
        stopLoop()
        start = nil
        player = nil
        for effect in effects { effect.stop() }
        effects.removeAll()
    }

    func effect(_ cue: WaterCue) {
        guard active, !interrupted, !muted else { return }
        let data = cueData[cue] ?? cue.wav()
        cueData[cue] = data
        #if targetEnvironment(simulator)
        traceAudio("effect", data: data)
        #else
        effects.removeAll { !$0.isPlaying }
        guard let effect = try? AVAudioPlayer(data: data) else { return }
        effect.prepareToPlay()
        if effect.play() {
            effects.append(effect)
            traceAudio("effect", data: data)
        }
        #endif
    }

    private func stopLoop() {
        #if targetEnvironment(simulator)
        if start != nil, signal != nil, !muted { traceAudio("stop") }
        #else
        guard let player else { return }
        traceAudio("stop")
        player.stop()
        #endif
    }

    private func resume() {
        guard active, !interrupted, start == nil, let signal else { return }
        if !muted {
            let data = signal.wav()
            let offset = elapsed.truncatingRemainder(dividingBy: signal.duration)
            #if targetEnvironment(simulator)
            traceAudio("loop", data: data, offset: offset)
            #else
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(data: data)
            player?.numberOfLoops = -1
            player?.currentTime = offset
            player?.prepareToPlay()
            player?.volume = 0
            if player?.play() == true {
                player?.setVolume(1, fadeDuration: 0.14)
                traceAudio("loop", data: data, offset: offset)
            }
            #endif
        }
        start = ProcessInfo.processInfo.systemUptime
    }

    // Archive PCM and game timestamps so simulator recordings can be mixed offline.
    private func traceAudio(_ kind: String, data: Data? = nil, offset: Double = 0) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--capture-audio"),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let now = Date().timeIntervalSince1970
        let folder = documents.appendingPathComponent("motion-audio")
        let timestamp = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), now)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = kind + "-" + timestamp
        let audio = data == nil ? "" : name + ".wav"
        if let data { try? data.write(to: folder.appendingPathComponent(audio)) }
        let row = [timestamp, kind, audio, String(offset)].joined(separator: ",")
        try? row.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        #endif
    }

}

func holeName(_ index: Int) -> String { ["A", "B", "C", "D", "E"][index] }
func levelText(_ strength: Double) -> String { "\(Int((strength * 100).rounded()))%" }

func depthSelector(_ game: LakeGame, large: Bool = false) -> some View {
    HStack(spacing: 6) {
        ForEach(depthKeys.indices, id: \.self) { depth in
            FieldButton(text: tr(depthKeys[depth]), icon: depth == 0 ? "water.waves" : "arrow.down",
                        filled: game.trip.depth == depth, large: large) { game.setDepth(depth) }
                .accessibilityAddTraits(game.trip.depth == depth ? .isSelected : [])
                .accessibilityIdentifier("depth-\(depth)")
        }
    }
}

struct IceMap: View {
    @ObservedObject var game: LakeGame
    @ObservedObject var radio: LakeRadio
    var area: CGRect
    @State private var finger: CGPoint?
    @State private var grab: CGSize?
    @State private var contact: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let spots = lakeHoles[game.level.lake].map {
                CGPoint(x: area.minX + $0.x * area.width, y: area.minY + $0.y * area.height)
            }
            let large = size.width >= 690
            let jack = CGPoint(x: area.minX + area.width * 0.52, y: area.maxY - (large ? 36 : 22))
            let selectedSpot = game.trip.hole.map { spots[$0] }
            let resting = selectedSpot.map {
                CGPoint(x: min(size.width - 36, $0.x + (large ? 58 : 44)), y: $0.y + 13)
            } ?? jack
            let end = finger ?? resting

            ZStack(alignment: .topLeading) {
                IceArt(seed: game.level.lake, bankLine: min(0.94, (area.maxY - 18) / size.height))
                    .ignoresSafeArea()
                ZStack {
                    IceCable(anchor: jack, end: end)
                        .stroke(ink.opacity(0.36), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .offset(y: 2)
                    IceCable(anchor: jack, end: end)
                        .stroke(orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    IceCable(anchor: jack, end: end)
                        .stroke(snow.opacity(0.6), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                }
                .allowsHitTesting(false)

                Text(watchTime(game.trip.minute))
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(snow, in: Capsule())
                    .position(x: area.minX + 38, y: area.minY - 8)
                    .accessibilityIdentifier("watch-time")
                    .allowsHitTesting(false)

                ForEach(spots.indices, id: \.self) { index in
                    let selected = game.trip.hole == index
                    let marks = game.trip.pins.filter { $0.hole == index }
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.76)) {
                            game.select(index)
                        }
                    } label: {
                        ZStack {
                            IceHole(seed: index + game.level.lake * 5, selected: selected)
                                .frame(width: 63, height: 55)
                                .scaleEffect(large ? 1.47 : 1.14)
                            Text(holeName(index))
                                .foregroundStyle(snow)
                                .font(.system(large ? .caption : .caption2, design: .monospaced, weight: .black))
                                .offset(y: 1)
                            if selected {
                                Image(systemName: "smallcircle.filled.circle")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(orange)
                                    .background(ink, in: Circle())
                                    .offset(x: 14, y: 8)
                            }
                            if let mark = marks.last {
                                HStack(spacing: 3) {
                                    Image(systemName: ["circle.fill", "triangle.fill", "diamond.fill"][mark.id % 3])
                                        .font(.system(size: 6, weight: .bold))
                                    Text(mark.time).font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .padding(4).background(snow, in: Capsule())
                                .offset(y: large ? 35 : 27)
                            }
                        }
                        .frame(width: large ? 84 : 60, height: large ? 78 : 56)
                    }
                    .buttonStyle(.plain)
                    .position(spots[index])
                    .accessibilityLabel(label("Hole %@", holeName(index)))
                    .accessibilityIdentifier("hole-\(index)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }

                if game.trip.id == "double", game.trip.hole == nil, finger == nil {
                    Text(tr("Drag hydrophone to a hole"))
                        .font(.system(.caption, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(snow, in: Capsule())
                        .position(x: jack.x, y: jack.y - 32)
                        .allowsHitTesting(false)
                }

                if let spot = selectedSpot, finger == nil {
                    Path { lead in
                        lead.move(to: end)
                        lead.addQuadCurve(to: spot, control: CGPoint(x: spot.x + 18, y: end.y + 5))
                    }
                    .stroke(ink.opacity(0.88), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .allowsHitTesting(false)
                    if let contact {
                        IceEntry(start: contact)
                            .frame(width: 92, height: 68)
                            .position(spot)
                            .allowsHitTesting(false)
                    }
                }

                ZStack {
                    Rectangle().fill(.clear)
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ink).frame(width: 11, height: 12)
                        ZStack {
                            Capsule().fill(LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.34), orange],
                                                          startPoint: .top, endPoint: .bottom))
                            Capsule().strokeBorder(ink.opacity(0.44), lineWidth: 1)
                            HStack(spacing: 4) {
                                ForEach(0..<3) { _ in
                                    Capsule().fill(ink.opacity(0.73)).frame(width: 2, height: 10)
                                }
                                Circle().fill(snow).frame(width: 4, height: 4).padding(.leading, 4)
                            }
                        }
                        .frame(width: large ? 60 : 46, height: large ? 25 : 22)
                    }
                    .shadow(color: ink.opacity(0.36), radius: 3, x: 2, y: 3)
                    .rotationEffect(.degrees(finger == nil && selectedSpot != nil ? -14 : 0))
                }
                    .frame(width: large ? 88 : 68, height: large ? 54 : 48)
                    .contentShape(Rectangle())
                    .position(end)
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named("ice-map"))
                            .onChanged { drag in
                                if grab == nil {
                                    grab = CGSize(width: resting.x - drag.startLocation.x,
                                                  height: resting.y - drag.startLocation.y)
                                }
                                finger = CGPoint(x: drag.location.x + (grab?.width ?? 0),
                                                 y: drag.location.y + (grab?.height ?? 0))
                            }
                            .onEnded { drag in
                                let destination = finger ?? drag.location
                                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.76)) {
                                    if let index = spots.indices.min(by: {
                                        spots[$0].distance(to: destination) < spots[$1].distance(to: destination)
                                    }), spots[index].distance(to: destination) < (large ? 57 : 45) {
                                        game.select(index)
                                    }
                                    finger = nil
                                    grab = nil
                                }
                            }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tr("Drag hydrophone to a hole"))
                    .accessibilityIdentifier("hydrophone")
            }
            .coordinateSpace(name: "ice-map")
            .onChange(of: game.trip.hole) { _, hole in
                guard hole != nil else { return }
                contact = Date()
                radio.effect(.probe)
            }
            .task(id: contact) {
                guard contact != nil else { return }
                try? await Task.sleep(for: .seconds(1.1))
                if !Task.isCancelled { contact = nil }
            }
        }
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

struct IceCable: Shape {
    let anchor: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(end.x, end.y) }
        set { end = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var wire = Path()
        let dx = end.x - anchor.x
        let dy = end.y - anchor.y
        let distance = hypot(dx, dy)
        guard distance > 3 else { return wire }
        let slack = min(58, distance * 0.42) / (1 + distance / 235)
        let side = -dx / (abs(dx) + 38)
        wire.move(to: anchor)
        wire.addCurve(to: end,
                      control1: CGPoint(x: anchor.x + dx * 0.18 + side * slack,
                                        y: anchor.y + dy * 0.24 + slack * 0.5),
                      control2: CGPoint(x: end.x - dx * 0.29 + side * slack * 0.25,
                                        y: end.y - dy * 0.29 + slack * 0.91))
        return wire
    }
}

struct IceEntry: View {
    var start: Date

    var body: some View {
        TimelineView(.animation) { frame in
            let age = max(0, frame.date.timeIntervalSince(start))
            Canvas { ctx, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0..<3 {
                    let t = smooth((age - Double(index) * 0.09) / 0.75)
                    let radius = 5 + t * 33
                    let ripple = CGRect(x: centre.x - radius, y: centre.y - radius * 0.61,
                                        width: radius * 2, height: radius * 1.22)
                    ctx.stroke(Path(ellipseIn: ripple), with: .color(ice.opacity((1 - t) * 0.72)),
                               lineWidth: 1.1)
                }
                for index in 0..<7 {
                    let t = smooth((age - Double(index % 3) * 0.055) / 0.56)
                    let angle = Double(index) * 2.4
                    let x = centre.x + cos(angle) * t * Double(9 + index % 4 * 4)
                    let y = centre.y + sin(angle) * t * 12
                    let diameter = 2.0 + Double(index % 3)
                    let bubble = CGRect(x: x, y: y, width: diameter, height: diameter)
                    ctx.stroke(Path(ellipseIn: bubble), with: .color(snow.opacity((1 - t) * 0.78)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct IceHole: View {
    var seed: Int
    var selected: Bool

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width * 0.50, y: size.height * 0.49)
            func brokenRing(_ radius: Double, _ slope: Double, _ offset: Double) -> Path {
                var ring = Path()
                for point in 0..<26 {
                    let a = Double(point) / 26 * 2 * .pi
                    let chip = Double((point * 71 + seed * 13) % 9) / 8
                    let r = radius * (1 - chip * 0.22)
                    let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r * slope + offset)
                    if point == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
                }
                ring.closeSubpath()
                return ring
            }
            ctx.fill(brokenRing(30, 0.78, 4), with: .color(ink.opacity(0.24)))
            ctx.fill(brokenRing(29, 0.77, 0), with: .color(snow))
            ctx.fill(brokenRing(24, 0.79, -1), with: .color(gauge.opacity(0.79)))
            ctx.fill(brokenRing(21, 0.72, 0), with: .radialGradient(
                Gradient(colors: [Color(red: 0.02, green: 0.07, blue: 0.09), ink]),
                center: center, startRadius: 2, endRadius: 23
            ))
            if selected {
                ctx.stroke(brokenRing(27, 0.77, 0), with: .color(orange), lineWidth: 2)
            }
            for i in 0..<6 {
                let a = Double(i * 31 + seed * 7) * .pi / 90
                let rad = Double(i % 3 + 24)
                let x = center.x + cos(a) * rad
                let y = center.y + sin(a) * rad * 0.76
                var chip = Path()
                chip.addLines([CGPoint(x: x - 3, y: y - 1), CGPoint(x: x + 3, y: y - 3),
                               CGPoint(x: x + 5, y: y + 1), CGPoint(x: x, y: y + 3)])
                chip.closeSubpath()
                ctx.fill(chip, with: .color(i % 2 == 0 ? snow : ice))
            }
        }
        .accessibilityHidden(true)
    }
}

struct IceArt: View {
    var seed: Int
    var bankLine: Double?

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            func random(_ i: Int, _ salt: Int) -> Double {
                let point = i * i * 23 + i * (19 + salt * 11)
                let offset = seed * 107 + salt * 137
                return Double((point + offset) % 1009) / 1009
            }
            let blue = Color(red: 0.63, green: 0.77, blue: 0.79)
            let inlet = Color(red: 0.24, green: 0.43, blue: 0.48)
            let rock = Color(red: 0.36, green: 0.38, blue: 0.35)
            let bark = Color(red: 0.39, green: 0.30, blue: 0.22)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [snow, ice, blue]), startPoint: at(0, 0), endPoint: at(0.8, 1)
            ))
            for i in 0..<74 {
                let x = random(i, 2)
                let y = random(i, 4)
                let r = (0.012 + random(i, 6) * 0.11) * min(w, h)
                let rect = CGRect(x: x * w - r, y: y * h - r, width: r * 2, height: r * 1.4)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [i % 3 == 0 ? blue.opacity(0.5) : snow.opacity(0.8), .clear]),
                    center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: r
                ))
            }
            func bank(_ base: Double, _ scale: Double) -> Path {
                var shape = Path()
                shape.move(to: at(-0.07, 1.10))
                for i in 0...47 {
                    let x = Double(i) / 46
                    let curve = sin(x * 6.1 + Double(seed) * 1.5) * 0.069
                    let crag = sin(x * 16 - 0.8) * 0.046 + (random(i, 8) - 0.5) * 0.027
                    shape.addLine(to: at(x, base + curve * scale + crag))
                }
                shape.addLine(to: at(1.04, 1.10))
                shape.closeSubpath()
                return shape
            }
            let bankY = bankLine ?? [0.85, 0.81, 0.91][seed]
            ctx.fill(bank(bankY - 0.026, 1), with: .color(blue.opacity(0.78)))
            ctx.fill(bank(bankY, 1), with: .linearGradient(
                Gradient(colors: [inlet, ink]), startPoint: at(0.24, 0.74), endPoint: at(0.35, 1)
            ))
            ctx.fill(bank(bankY + 0.082, 1.08), with: .color(blue))
            ctx.fill(bank(bankY + 0.104, 1.12), with: .color(snow))
            for index in 0..<7 {
                let x = 0.04 + random(index, 17) * 0.92
                let y = 0.17 + random(index, 13) * 0.64
                var crack = Path()
                crack.move(to: at(x - 0.16, y + 0.13))
                for step in 0...10 {
                    let u = Double(step) / 10
                    crack.addLine(to: at(x - 0.15 + 0.27 * u,
                                        y + 0.073 * sin(u * 7 + Double(index)) + (random(step, index) - 0.5) * 0.045))
                }
                ctx.stroke(crack, with: .color(inlet.opacity(0.18)), lineWidth: 1)
                ctx.stroke(crack.offsetBy(dx: 0, dy: 1), with: .color(snow.opacity(0.68)), lineWidth: 1.3)
            }
            for i in 0..<280 {
                let u = random(i, 22)
                let v = random(i, 16)
                let length = Double(i % 4 + 1)
                let dot = CGRect(x: u * w, y: v * h, width: length, height: 1 + Double(i % 2) * 0.5)
                ctx.fill(Path(ellipseIn: dot), with: .color(i % 5 == 0 ? ink.opacity(0.20) : snow.opacity(0.68)))
            }

            switch seed {
            case 1:
                for i in 0..<64 {
                    let x = 0.014 + random(i, 21) * 0.34
                    let y = bankY - 0.022 + random(i, 32) * 0.21 - x * 0.18
                    let lean = (random(i, 18) - 0.32) * 0.08
                    let top = y - 0.041 - random(i, 12) * 0.13
                    var reed = Path()
                    reed.move(to: at(x, y))
                    reed.addQuadCurve(to: at(x + lean, top), control: at(x + lean * 0.28, y - 0.09))
                    ctx.stroke(reed, with: .color(i % 3 == 0 ? bark : rock), lineWidth: i % 3 == 0 ? 2 : 1)
                    let tip = at(x + lean, top)
                    ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 1.4, y: tip.y - 2, width: 3.1, height: 7.5)),
                             with: .color(bark))
                }
            case 2:
                var shadow = Path()
                shadow.addLines([at(0.75, -0.05), at(0.95, -0.05), at(0.91, 0.42), at(0.78, 0.35)])
                shadow.closeSubpath()
                ctx.fill(shadow, with: .color(ink.opacity(0.30)))
                for i in 0..<10 {
                    let y = Double(i) * 0.032 - 0.048
                    let x = 0.77 - y * 0.32
                    var plank = Path()
                    plank.addLines([at(x, y), at(x + 0.15, y + 0.025), at(x + 0.14, y + 0.05), at(x - 0.006, y + 0.022)])
                    plank.closeSubpath()
                    ctx.fill(plank, with: .color(i % 3 == 0 ? rock : bark))
                    ctx.stroke(plank, with: .color(snow.opacity(0.38)), lineWidth: 1)
                }
                for i in 0..<4 {
                    let p = at(0.793 + Double(i % 2) * 0.131 - Double(i / 2) * 0.061, 0.045 + Double(i / 2) * 0.231)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y, width: 11, height: 12)), with: .color(ink))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 1, width: 8, height: 7)), with: .color(snow))
                }
            default:
                for i in 0..<15 {
                    let x = 0.62 + random(i, 11) * 0.38
                    let y = bankY + 0.043 + random(i, 9) * 0.13
                    let stone = at(x, y)
                    let r = 2 + random(i, 29) * 13
                    var face = Path()
                    face.addLines([CGPoint(x: stone.x - r, y: stone.y + r * 0.2),
                                   CGPoint(x: stone.x - r * 0.4, y: stone.y - r * 0.64),
                                   CGPoint(x: stone.x + r * 0.7, y: stone.y - r * 0.44),
                                   CGPoint(x: stone.x + r, y: stone.y + r * 0.31)])
                    face.closeSubpath()
                    ctx.fill(face, with: .color(i % 3 == 0 ? rock : gauge))
                    ctx.stroke(face.offsetBy(dx: 0, dy: -1), with: .color(snow.opacity(0.69)), lineWidth: 1.2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ReceiverPanel: View {
    @ObservedObject var game: LakeGame
    @ObservedObject var radio: LakeRadio
    var fieldHeight: CGFloat?
    var toggle: () -> Void
    @State private var dragStart: Int?

    var large: Bool { fieldHeight != nil }

    var body: some View {
        let screenHeight = fieldHeight.map { min(155, max(82, $0 * 0.29)) } ?? 56
        let wheel: CGFloat = large ? 74 : 53
        return VStack(spacing: large ? 10 : 6) {
            HStack {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                        caption(tr("Hydrophone"))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Hide receiver"))
                .accessibilityIdentifier("receiver-drawer")
                Spacer()
                caption(label("Channel %d", game.trip.tune + 1))
            }
            HStack(spacing: 11) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    let phase = radio.phase
                    VStack(alignment: .leading, spacing: 3) {
                        SignalTape(signal: radio.signal, phase: phase)
                            .frame(height: screenHeight)
                            .background(ink, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.black.opacity(0.48), lineWidth: 2)
                                    .padding(1)
                            }
                            .overlay(alignment: .topLeading) {
                                Capsule().fill(snow.opacity(0.20)).frame(width: 53, height: 1)
                                    .padding(.leading, 10).padding(.top, 5)
                            }
                            .allowsHitTesting(false)
                        HStack {
                            Text(tr("LEVEL"))
                            Spacer()
                            Text(game.live.map { levelText($0.strength) } ?? "—")
                                .accessibilityIdentifier("live-strength")
                            if let reading = game.live {
                                Spacer()
                                Image(systemName: "scope")
                                Text(levelText(reading.clarity))
                                    .accessibilityLabel(tr("Tuning clarity"))
                                    .accessibilityValue(levelText(reading.clarity))
                                    .accessibilityIdentifier("live-clarity")
                            }
                        }
                        .font(.system(large ? .caption : .caption2, design: .monospaced, weight: .bold))
                        Meter(strength: game.live?.strength ?? 0, pulse: radio.signal?.amplitude(phase) ?? 0)
                            .frame(height: large ? 28 : 18)
                    }
                }
                VStack(spacing: large ? 9 : 3) {
                    ZStack {
                        Circle().fill(ink.opacity(0.58)).padding(-3)
                        Circle().fill(LinearGradient(colors: [gauge, ink, .black.opacity(0.79)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: .black.opacity(0.40), radius: 2, y: 3)
                        Circle().strokeBorder(snow.opacity(0.39), style: StrokeStyle(lineWidth: 3, dash: [2, 4])).padding(4)
                        Circle().strokeBorder(snow.opacity(0.13), lineWidth: 1).padding(11)
                        Capsule().fill(orange)
                            .frame(width: large ? 6 : 4, height: large ? 17 : 12)
                            .offset(y: large ? -24 : -18)
                            .rotationEffect(.degrees(Double(game.trip.tune - 2) * 36))
                    }
                    .frame(width: wheel, height: wheel)
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { drag in
                            if dragStart == nil { dragStart = game.trip.tune }
                            let by = Int(((drag.translation.width - drag.translation.height) / 21).rounded())
                            game.tune((dragStart ?? 0) + by)
                        }
                        .onEnded { _ in dragStart = nil })
                    .accessibilityLabel(tr("Tuning wheel"))
                    .accessibilityValue(label("Channel %d", game.trip.tune + 1))
                    .accessibilityAdjustableAction { direction in
                        game.tune(game.trip.tune + (direction == .increment ? 1 : -1))
                    }
                    HStack(spacing: 4) {
                        step(-1, "minus")
                        step(1, "plus")
                    }
                }
            }
            depthSelector(game, large: large)
            HStack(spacing: 6) {
                FieldButton(text: tr("Pin reading"), icon: "pin", large: large) { game.pin() }
                    .disabled(game.live == nil).opacity(game.live == nil ? 0.54 : 1)
                    .accessibilityIdentifier("pin")
                FieldButton(text: tr("Set rig"), icon: "arrow.right", filled: true, large: large) { game.rig() }
                    .disabled(game.live == nil).opacity(game.live == nil ? 0.54 : 1)
                    .accessibilityIdentifier("rig")
            }
            if game.level.moving {
                FieldButton(text: tr("Advance watch"), icon: "clock.arrow.circlepath", large: large) { game.waitMinute() }
                    .accessibilityIdentifier("wait")
            }
        }
        .padding(.horizontal, large ? 14 : 11)
        .padding(.bottom, large ? 14 : 11)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.57, blue: 0.30), orange, Color(red: 0.84, green: 0.35, blue: 0.14)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(ink.opacity(0.36), lineWidth: 1) }
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(snow.opacity(0.26), lineWidth: 1).padding(3) }
                .shadow(color: ink.opacity(0.19), radius: 2, y: 3)
        }
    }

    func step(_ change: Int, _ icon: String) -> some View {
        Button { game.tune(game.trip.tune + change) } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .frame(width: large ? 55 : 44, height: large ? 54 : 44)
                .background(snow, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(change == 1 ? "Tune up" : "Tune down"))
        .accessibilityIdentifier(change == 1 ? "tune-up" : "tune-down")
    }
}

struct LiveTape: View {
    @ObservedObject var radio: LakeRadio

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            SignalTape(signal: radio.signal, phase: radio.phase)
        }
    }
}

struct SignalTape: View {
    var signal: Signal?
    var phase: Double?

    var body: some View {
        Canvas { ctx, size in
            let height = size.height
            let width = size.width
            let baseline = height * 0.67
            for index in 1..<16 {
                let x = width * Double(index) / 16
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: 3))
                grid.addLine(to: CGPoint(x: x, y: height - 3))
                ctx.stroke(grid, with: .color(ice.opacity(0.13)), lineWidth: 1)
            }
            var line = Path()
            for index in 0...144 {
                let u = Double(index) / 144
                let tone = signal?.amplitude(u * (signal?.duration ?? 1)) ?? 0
                let rustle = (signal?.noise ?? 0.05) * (1 - (signal?.clarity ?? 0) * 0.7)
                let y = baseline - tone * height * (0.29 + (signal?.clarity ?? 0) * 0.34)
                    + sin(u * 180) * rustle * height * 0.18
                let point = CGPoint(x: u * width, y: y)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            ctx.stroke(line, with: .color(ice), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            if let phase, let signal {
                let x = min(width - 2, width * phase / signal.duration)
                let hot = signal.amplitude(phase)
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 3))
                marker.addLine(to: CGPoint(x: x, y: height - 3))
                ctx.stroke(marker, with: .color(orange), lineWidth: hot > 0.1 ? 3 : 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

struct Meter: View {
    var strength: Double
    var pulse: Double

    var body: some View {
        let peak = min(0.98, strength * 0.88 + pulse * 0.14)
        Canvas { ctx, size in
            let y = size.height - 1
            for tick in 0...20 {
                let x = 5 + Double(tick) * (size.width - 10) / 20
                var path = Path()
                path.move(to: CGPoint(x: x, y: y - (tick % 5 == 0 ? 11 : 6)))
                path.addLine(to: CGPoint(x: x, y: y))
                ctx.stroke(path, with: .color(ink.opacity(0.65)), lineWidth: 1)
            }
            var needle = Path()
            needle.move(to: CGPoint(x: 6 + peak * (size.width - 12), y: y))
            needle.addLine(to: CGPoint(x: 9 + peak * (size.width - 12), y: 1))
            ctx.stroke(needle, with: .color(snow), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

struct StrikeControl: View {
    @ObservedObject var radio: LakeRadio
    var large = false
    var action: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.09)) { _ in
            let ready = radio.played >= (radio.signal?.duration ?? 1.5) + 0.1
            FieldButton(text: tr(ready ? "Strike on repeat" : "Listen for the repeat"),
                        icon: "arrow.up", filled: ready, large: large, action: action)
                .disabled(!ready)
                .accessibilityIdentifier("strike")
        }
    }
}

struct WaterClock {
    var age = 0.0
    var cast = -1.0
    var down = false
    var entry = -1.0
    var splash = -1.0
    var escape = -1.0
    var pullBack = 1.0
    var pass = -1.0
    var hand = LineHand.none
    var pulse = LineHand.none
    var pulseLeft = 0.0
    var pressedAt = 0.0
    var lastGesture = -1.0
    var lastSave = 0.0
    var nextClick = 0.0
    var motion = FightMotion()
}

struct WaterStage: View {
    @ObservedObject var game: LakeGame
    @ObservedObject var radio: LakeRadio
    let area: CGRect
    let wide: Bool
    let awake: Bool
    @State private var clock = WaterClock()

    var phase: String { game.trip.phase }
    var descent: Double { game.trip.depth == 0 ? 1.24 : 1.57 }
    var activeHand: LineHand { clock.hand == .none && clock.pulseLeft > 0 ? clock.pulse : clock.hand }
    var fishIndex: Int { game.campaign.fish.firstIndex(where: { $0.id == game.level.source }) ?? 0 }

    var waterView: LineWater {
        LineWater(area: area, clock: clock, phase: phase, depth: game.trip.depth,
                  feedback: game.trip.feedback, fishIndex: fishIndex,
                  beacon: game.level.id == "broadcast",
                  beat: phase == "bite" ? radio.signal?.amplitude(radio.phase) ?? 0 : 0,
                  hole: game.trip.hole ?? 0)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            waterView.accessibilityHidden(true)
            controls
                .frame(maxWidth: wide ? 490 : .infinity)
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
        }
        .onAppear {
            if phase == "fight" {
                var motion = FightMotion()
                motion.memory = game.trip.fight ?? FightMemory()
                motion.y = blend(game.trip.depth == 0 ? 0.58 : 0.82, 0.25, motion.memory.winding)
                motion.rodLoad = motion.memory.load
                clock.motion = motion
            }
        }
        .onChange(of: awake) { _, awake in
            if !awake { restHand() }
        }
        .onDisappear { restHand() }
        .onChange(of: game.trip.depth) { _, _ in
            clock.pullBack = clock.down ? 0 : 1
            clock.down = false
            clock.pass = -1
        }
        .task(id: awake) {
            guard awake else { return }
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(17))
                guard !Task.isCancelled else { break }
                let now = ProcessInfo.processInfo.systemUptime
                advance(min(0.045, now - last))
                last = now
            }
        }
    }

    func restHand() {
        clock.hand = .none
        clock.pulseLeft = 0
        if phase == "fight" { game.rememberFight(clock.motion.memory) }
    }

    func advance(_ dt: Double) {
        var next = clock
        next.age += dt
        if next.pass >= 0 { next.pass += dt }
        if next.entry >= 0 { next.entry += dt }
        if next.splash >= 0 { next.splash += dt }
        if next.escape >= 0 { next.escape += dt }
        if next.pullBack < 1 { next.pullBack = min(1, next.pullBack + dt * 2.6) }
        if next.cast >= 0 {
            next.cast += dt
            let render = waterView
            let p = render.lineDescent(next.cast, duration: descent)
            if next.entry < 0 && render.baitDepth(progress: p, scale: render.stageScale) >= area.minY {
                next.entry = 0
                radio.effect(.enter)
            }
            if next.cast >= descent {
                next.cast = -1
                next.down = true
                next.age = 0
                next.pass = 0
                clock = next
                game.drop()
                return
            }
        }

        if phase == "fight" {
            let hand = activeHand
            next.motion.advance(dt, hand: hand, depth: game.trip.depth, lake: game.level.lake,
                                anchored: game.level.id == "broadcast")
            next.pulseLeft = max(0, next.pulseLeft - dt)
            if hand == .wind && next.age >= next.nextClick && !next.motion.arrived {
                radio.effect(.crank)
                next.nextClick = next.age + 0.34
            }
            if next.motion.failed {
                next.pass = -1
                next.down = false
                next.escape = 0
                next.hand = .none
                next.pulseLeft = 0
                clock = next
                radio.effect(.snap)
                game.finishFight(landed: false)
                return
            }
            if next.motion.arrived && next.motion.lift >= 0.59 && next.splash < 0 {
                next.splash = 0
                radio.effect(.splash)
            }
            if next.motion.lift > 2.34 {
                clock = next
                game.finishFight(landed: true)
                return
            }
            if next.age - next.lastSave > 0.42 {
                next.lastSave = next.age
                game.rememberFight(next.motion.memory)
            }
        }
        clock = next
    }

    func drop() {
        guard phase == "rig", clock.cast < 0 else { return }
        clock.cast = 0
        clock.entry = -1
        clock.escape = -1
        clock.pass = -1
        clock.down = false
        clock.pullBack = 1
    }

    func hook() {
        let render = waterView
        let scale = render.stageScale
        let opening = CGPoint(x: area.width * 0.48, y: area.minY)
        let bait = render.baitPoint(opening: opening, progress: 1, scale: scale)
        let contact = render.fishPosition(bait: bait, opening: opening, width: area.width,
                                          water: area.height, scale: scale)
        var motion = FightMotion()
        motion.x = contact.point.x / area.width
        motion.y = (contact.point.y - area.minY) / area.height
        motion.heading = contact.angle
        motion.vx = -0.19
        clock.motion = motion
        clock.hand = .none
        clock.pulseLeft = 0
        clock.lastGesture = -1
        clock.splash = -1
        clock.age = 0
        clock.nextClick = 0
        clock.lastSave = 0
        radio.effect(.strike)
        game.strike()
    }

    func startHand(_ hand: LineHand) {
        guard !clock.motion.arrived, clock.hand == .none else { return }
        clock.hand = hand
        clock.pulseLeft = 0
        clock.pressedAt = clock.age
        clock.nextClick = clock.age
        if hand == .ease { radio.effect(.release) }
    }

    func finishHand(_ hand: LineHand) {
        guard clock.hand == hand else { return }
        clock.hand = .none
        clock.lastGesture = clock.age
        if clock.age - clock.pressedAt < 0.18 {
            clock.pulse = hand
            clock.pulseLeft = 0.37
        }
        game.rememberFight(clock.motion.memory)
    }

    func tapHand(_ hand: LineHand) {
        guard clock.hand == .none, clock.age - clock.lastGesture > 0.15, !clock.motion.arrived else { return }
        clock.pulse = hand
        clock.pulseLeft = 0.47
        if hand == .ease { radio.effect(.release) }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: wide ? 12 : 8) {
            if phase == "rig" {
                if !game.trip.feedback.isEmpty && clock.cast < 0 {
                    Text(tr(game.trip.feedback))
                        .font(.callout.weight(.semibold)).padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityIdentifier("diagnostic")
                }
                caption(clock.cast >= 0 ? tr("Lowering the line") : label("Rig at hole %@", holeName(game.trip.hole ?? 0)))
                    .accessibilityIdentifier("rig-state")
                depthSelector(game, large: wide).disabled(clock.cast >= 0)
                HStack(spacing: 5) {
                    ForEach(lureKeys.indices, id: \.self) { lure in
                        FieldButton(text: tr(lureKeys[lure]), icon: lureIcons[lure],
                                    filled: game.trip.lure == lure, large: wide) { game.setLure(lure) }
                            .accessibilityIdentifier("lure-\(lure)")
                    }
                }
                .disabled(clock.cast >= 0)
                HStack {
                    FieldButton(text: tr("Back to readings"), icon: "arrow.uturn.backward", large: wide) { game.listen() }
                        .accessibilityIdentifier("back-readings")
                    FieldButton(text: tr(game.level.id == "broadcast" ? "Lower grapnel" : "Drop line"),
                                icon: "arrow.down.to.line", filled: true, large: wide, action: drop)
                        .accessibilityIdentifier("drop")
                }
                .disabled(clock.cast >= 0)
            } else if phase == "bite" {
                caption(tr("Bite on the line"))
                LiveTape(radio: radio).frame(height: wide ? 56 : 42)
                    .background(ink, in: RoundedRectangle(cornerRadius: 7))
                StrikeControl(radio: radio, large: wide, action: hook)
            } else {
                let load = clock.motion.memory.load
                let amount = clock.motion.memory.winding
                HStack {
                    caption(tr("Line tension"))
                    Spacer()
                    Text(levelText(clamp(load))).font(.caption.monospacedDigit().weight(.heavy))
                }
                let warning = load >= 0.76
                ProgressView(value: clamp(load))
                    .tint(warning ? orange : gauge)
                    .accessibilityLabel(tr("Line tension"))
                    .accessibilityValue(levelText(clamp(load)))
                    .accessibilityIdentifier("tension")
                HStack {
                    Text(tr(clock.motion.arrived ? "Landing the catch" : warning ? "Ease the line" : "Wind towards the hole"))
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier(clock.motion.lift >= 1.18 ? "catch-on-ice" : "line-in-water")
                    Spacer()
                    let wound = levelText(clamp(amount / (game.level.lake == 0 ? 0.88 : 0.96)))
                    Text(wound)
                        .font(.footnote.monospacedDigit().weight(.medium))
                        .accessibilityLabel(tr("Line wound"))
                        .accessibilityValue(wound)
                        .accessibilityIdentifier("winding")
                }
                HStack {
                    handButton(.wind, "Hold to reel", "arrow.clockwise", id: "reel", filled: !warning)
                    handButton(.ease, "Hold to ease", "arrow.uturn.backward", id: "ease", filled: warning)
                }
                .disabled(clock.motion.arrived)
            }
        }
        .padding(wide ? 14 : 10)
        .background(snow, in: RoundedRectangle(cornerRadius: 15))
    }

    func handButton(_ hand: LineHand, _ text: String, _ icon: String, id: String, filled: Bool) -> some View {
        FieldButton(text: tr(text), icon: icon, filled: filled || activeHand == hand, large: wide) {
            tapHand(hand)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startHand(hand) }
                .onEnded { _ in finishHand(hand) }
        )
        .accessibilityIdentifier(id)
    }
}

struct LineWater: View {
    let area: CGRect
    let clock: WaterClock
    let phase: String
    let depth: Int
    let feedback: String
    let fishIndex: Int
    let beacon: Bool
    let beat: Double
    let hole: Int

    var stageScale: Double { min(1.55, max(0.94, area.width / 495)) }

    func lineDescent(_ time: Double, duration: Double) -> Double {
        smooth((time - 0.09) / (duration - 0.13))
    }

    func baitDepth(progress: Double, scale: Double) -> Double {
        let depthRatio = depth == 0 ? 0.55 : 0.88
        let travel = progress * (20 * scale + depthRatio * area.height)
        return area.minY - 20 * scale + travel - beat * 9
    }

    func baitPoint(opening: CGPoint, progress: Double, scale: Double) -> CGPoint {
        let drift = sin(clock.age * 2.4) * 4
        let arc = 10 * sin(Double.pi * progress)
        return CGPoint(x: opening.x + (drift + arc) * scale,
                       y: baitDepth(progress: progress, scale: scale))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let w = size.width
                let surface = area.minY
                let water = area.height
                let scale = stageScale
                let opening = CGPoint(x: w * 0.48, y: surface)
                backdrop(ctx, size: size, opening: opening)
                let hooked = phase == "fight"
                let bend = hooked ? clock.motion.rodLoad : phase == "bite" ? 0.21 + beat * 0.36 : 0.12
                let tip = drawRig(ctx, width: w, surface: surface, bend: bend, scale: scale)
                let castTime = depth == 0 ? 1.24 : 1.57
                let rest = clock.down || phase == "bite" ? 1.0 : 0.0
                let lowering = clock.cast >= 0 ? lineDescent(clock.cast, duration: castTime) : max(rest, 1 - clock.pullBack)
                let recoil = clock.escape >= 0 && clock.escape < 0.5 ? (1 - smooth(clock.escape / 0.5)) * 0.46 : 0
                let descent = max(lowering, recoil)
                let bait = baitPoint(opening: opening, progress: descent, scale: scale)
                let length = min(w * 0.23, 118 * scale)
                let fish = fishPosition(bait: bait, opening: opening, width: w, water: water, scale: scale)
                let mouth = fish.point.offset(x: cos(fish.angle) * length * 0.45, y: sin(fish.angle) * length * 0.45)
                let clasp = fish.point.offset(x: 0, y: -18 * scale)
                let liftedEnd = beacon ? clasp : mouth
                let release = smooth((clock.motion.lift - 1.12) / 0.31)
                let restingLine = opening.offset(x: -9 * scale, y: 3 * scale)
                let looseEnd = CGPoint(x: blend(liftedEnd.x, restingLine.x, release),
                                       y: blend(liftedEnd.y, restingLine.y, release))
                let end = hooked ? looseEnd : bait

                drawLine(ctx, from: tip, through: opening, to: end, bend: bend, phase: phase)
                if let appearance = fish.opacity, appearance > 0.01 {
                    if beacon {
                        drawBeacon(ctx, at: fish.point, angle: fish.angle, scale: scale, opacity: appearance)
                    } else {
                        if hooked && clock.motion.lift > 1.04 {
                            let contact = smooth((clock.motion.lift - 1.04) / 0.22)
                            let shadow = CGRect(x: fish.point.x - length * 0.47,
                                                y: fish.point.y + length * 0.14,
                                                width: length * 0.91, height: 7 * scale)
                            ctx.fill(Path(ellipseIn: shadow), with: .color(ink.opacity(contact * 0.21)))
                        }
                        let flutter = hooked ? 1 - 0.94 * smooth((clock.motion.lift - 1.05) / 0.60) : 1
                        swimFish(ctx, centre: fish.point, heading: fish.angle, length: length,
                                 rhythm: fish.rhythm, energy: flutter, species: fishIndex, opacity: appearance)
                    }
                }
                if !hooked {
                    hookMark(ctx, point: bait, scale: scale, strength: pow(0.61, descent))
                }
                if clock.entry >= 0, clock.entry < 1.65 {
                    waterParticles(ctx, centre: opening, age: clock.entry, scale: scale, landing: false, bait: bait)
                }
                if hooked && clock.splash >= 0 {
                    waterParticles(ctx, centre: opening, age: clock.splash,
                                   scale: scale, landing: true, bait: end)
                }
            }
            caption(label("Hole %@", holeName(hole))).foregroundStyle(snow.opacity(0.83))
                .padding(.top, area.minY + 27).padding(.leading, 13)
        }
        .background(ink.ignoresSafeArea(edges: .bottom))
    }

    func fishPosition(bait: CGPoint, opening: CGPoint, width: Double, water: Double,
                      scale: Double) -> (point: CGPoint, angle: Double, rhythm: Double, opacity: Double?) {
        if phase == "fight" {
            let motion = clock.motion
            if motion.arrived {
                return landingPose(opening: opening, width: width, water: water, scale: scale)
            }
            let point = CGPoint(x: motion.x * width, y: opening.y + motion.y * water)
            return (point, motion.heading, motion.time * 14, 1)
        }
        if clock.escape >= 0 && clock.escape < 1.4 {
            let motion = clock.motion
            let side = motion.vx > 0 ? 1.0 : -1.0
            let t = clock.escape
            let x = (motion.x + side * t * (0.22 + t * 0.24)) * width
            let y = opening.y + (motion.y + t * 0.17) * water
            return (CGPoint(x: x, y: y), side > 0 ? 0.18 : .pi - 0.18, t * 19, 1 - t / 1.4)
        }
        if phase == "bite", beacon {
            let point = bait.offset(x: (8 + sin(clock.age * 2.1) * 3) * scale, y: 17 * scale)
            return (point, sin(clock.age * 2) * 0.3, 0, 0.94)
        }
        if phase == "bite" {
            let approach = smooth(clock.age / 0.69)
            let turn = sin(clock.age * 4.2) * 0.10
            let x = blend(width * 0.86, bait.x + min(width * 0.23, 118 * scale) * 0.49, approach)
            let y = bait.y + sin(clock.age * 3.3) * 10 * scale + (1 - approach) * 22 + beat * 10
            return (CGPoint(x: x, y: y), .pi + turn, clock.age * 9.3, min(1, approach + 0.2))
        }
        if phase == "rig", clock.pass >= 0 && clock.pass < 3.8 {
            if feedback.hasPrefix("Pass") || feedback.hasPrefix("Interest") || feedback.hasPrefix("Weak") {
                let t = clamp(clock.pass / 3.3)
                let x = blend(-width * 0.12, width * 1.13, t)
                let mismatch = feedback.hasPrefix("Pass above") ? -0.30 : feedback.hasPrefix("Pass below") ? 0.21 : 0.08
                let y = bait.y + mismatch * water + sin(t * 6.3) * 18 * scale
                return (CGPoint(x: x, y: y), cos(t * 6.3) * 0.13, t * 35, feedback.hasPrefix("Weak") ? 0.28 : 0.9)
            }
        }
        return (bait, 0, 0, nil)
    }

    func landingPose(opening: CGPoint, width: Double, water: Double,
                     scale: Double) -> (point: CGPoint, angle: Double, rhythm: Double, opacity: Double?) {
        let motion = clock.motion
        let age = motion.lift
        let length = min(width * 0.23, 118 * scale)
        let origin = CGPoint(x: motion.liftX * width, y: opening.y + motion.liftY * water)
        let restX = max(width * 0.244, length * 0.56 + 17)
        if beacon {
            let climb = smooth(age / 0.59)
            let across = smooth((age - 0.59) / 0.58)
            let x = blend(blend(origin.x, opening.x, climb), restX, across)
            let y = blend(origin.y, opening.y - 5, climb) + across * 13 - sin(across * .pi) * 8
            return (CGPoint(x: x, y: y), 0.1 * (1 - across), 0, 1)
        }

        let headLength = length * 0.45
        let startHead = origin.offset(x: cos(motion.heading) * headLength,
                                      y: sin(motion.heading) * headLength)
        let up = -.pi * 0.56
        let rotation = atan2(sin(up - motion.heading), cos(up - motion.heading))
        let aim = motion.heading + rotation * smooth(age / 0.30)
        let across = smooth((age - 0.59) / 0.58)
        let turnLeft = atan2(sin(-Double.pi - aim), cos(-Double.pi - aim))
        let angle = aim + turnLeft * smooth((age - 0.59) / 0.44)
        let climb = smooth(age / 0.59)
        let throughX = blend(startHead.x, opening.x, climb)
        let throughY = blend(startHead.y, opening.y, climb)
        let headX = blend(throughX, restX - headLength, across)
        let restY = opening.y + (width >= 690 ? 19 : 12)
        let arc = sin(across * Double.pi) * 9 * scale
        let headY = blend(throughY, restY, across) - arc
        // Keep the dorsal fin below the header even when the fish turns broadside.
        let clearance = width >= 690 ? 57.0 : 53.0
        let settledY = max(headY, clearance + abs(cos(angle)) * length * 0.28)
        let centre = CGPoint(x: headX - cos(angle) * headLength, y: settledY - sin(angle) * headLength)
        return (centre, angle, motion.time * 16, 1)
    }

    func backdrop(_ ctx: GraphicsContext, size: CGSize, opening: CGPoint) {
        let w = size.width
        let h = size.height
        let surface = opening.y
        let pale = Color(red: 0.28, green: 0.46, blue: 0.49)
        let dark = Color(red: 0.028, green: 0.079, blue: 0.12)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [pale, ink, dark]), startPoint: opening, endPoint: CGPoint(x: w * 0.53, y: h)))
        for i in 0..<8 {
            let ray = Double(i)
            let topX = opening.x - 44 + ray * 13
            var shaft = Path()
            shaft.move(to: CGPoint(x: topX, y: surface + 4))
            shaft.addLine(to: CGPoint(x: topX + (ray - 3.7) * 70, y: h * 0.82))
            shaft.addLine(to: CGPoint(x: topX + 30 + (ray - 3.4) * 74, y: h * 0.82))
            shaft.addLine(to: CGPoint(x: topX + 15, y: surface + 4))
            shaft.closeSubpath()
            ctx.fill(shaft, with: .linearGradient(
                Gradient(colors: [ice.opacity(0.10 + 0.02 * sin(clock.age * 0.55 + ray)), .clear]),
                startPoint: opening, endPoint: CGPoint(x: topX, y: h * 0.77)))
        }
        for i in 0..<32 {
            let k = Double(i)
            let x = (w * (0.03 + Double(i * 53 % 97) / 103) + sin(clock.age * 0.36 + k) * 8)
            let y = surface + 18 + (h - surface) * Double(i * 31 % 103) / 108 - cos(clock.age * 0.4 + k) * 7
            let d = Double(1 + i % 4) * 0.65
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                     with: .color(ice.opacity(Double(1 + i % 4) * 0.071)))
        }
        var shelf = Path()
        shelf.move(to: .zero)
        shelf.addLine(to: CGPoint(x: w, y: 0))
        for i in (0...24).reversed() {
            let x = w * Double(i) / 24
            let jag = sin(Double(i) * 0.84) * 4 + sin(Double(i) * 2.9) * 2.7
            let distance = abs(Double(i) / 24 - 0.235)
            let ledge = (w >= 690 ? 57.0 : 31.0) * (1 - smooth((distance - 0.14) / 0.11))
            shelf.addLine(to: CGPoint(x: x, y: surface + 9 + ledge + jag))
        }
        shelf.closeSubpath()
        ctx.fill(shelf, with: .linearGradient(Gradient(colors: [ice, snow, gauge]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: surface + 22)))
        let mouth = CGRect(x: opening.x - w * 0.117, y: surface - 8, width: w * 0.234, height: 18)
        ctx.fill(Path(ellipseIn: mouth.insetBy(dx: -6, dy: -4)), with: .color(snow))
        ctx.fill(Path(ellipseIn: mouth), with: .color(ink))
    }

    func drawRig(_ ctx: GraphicsContext, width: Double, surface: Double, bend: Double, scale: Double) -> CGPoint {
        let butt = CGPoint(x: width * 0.88, y: surface + 45 * scale + 5 * sin(clock.age * 1.6))
        let clearLanding = smooth((clock.motion.lift - 0.32) / 0.51)
        let tip = CGPoint(x: width * (0.487 + clearLanding * 0.107) + bend * 12 * scale,
                          y: surface - 25 * scale + bend * 64 * scale - clearLanding * 10 * scale)
        var rod = Path()
        rod.move(to: butt)
        rod.addCurve(to: tip,
                     control1: CGPoint(x: width * 0.78, y: surface - (57 + bend * 15) * scale),
                     control2: CGPoint(x: width * 0.64, y: surface - (28 + bend * 11) * scale))
        ctx.stroke(rod, with: .color(ink.opacity(0.94)), style: StrokeStyle(lineWidth: 10 * scale, lineCap: .round))
        ctx.stroke(rod, with: .color(orange), style: StrokeStyle(lineWidth: 6.4 * scale, lineCap: .round))
        ctx.stroke(rod, with: .color(snow.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        let grip = CGRect(x: butt.x - 5 * scale, y: butt.y - 8 * scale, width: 31 * scale, height: 21 * scale)
        ctx.fill(Path(roundedRect: grip, cornerRadius: 5 * scale), with: .color(ink))
        let reel = butt.offset(x: -17 * scale, y: 11 * scale)
        let radius = 17 * scale
        let disc = CGRect(x: reel.x - radius, y: reel.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: disc), with: .color(ink))
        ctx.stroke(Path(ellipseIn: disc.insetBy(dx: 2, dy: 2)), with: .color(gauge), lineWidth: 2)
        for i in 0..<6 {
            let angle = clock.motion.spool + Double(i) * .pi / 3
            let end = reel.offset(x: cos(angle) * radius * 0.73, y: sin(angle) * radius * 0.73)
            var spoke = Path()
            spoke.move(to: reel)
            spoke.addLine(to: end)
            ctx.stroke(spoke, with: .color(ice.opacity(0.43)), lineWidth: 1.3)
        }
        let knob = reel.offset(x: cos(clock.motion.spool) * radius, y: sin(clock.motion.spool) * radius)
        ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 4, y: knob.y - 4, width: 8, height: 8)), with: .color(orange))
        return tip
    }

    func drawLine(_ ctx: GraphicsContext, from tip: CGPoint, through opening: CGPoint,
                  to end: CGPoint, bend: Double, phase: String) {
        let slack = (1 - clamp(bend)) * (phase == "fight" ? 54.0 : 22.0)
        let descent = max(0, end.y - opening.y)
        let atIce = CGPoint(x: blend(tip.x, opening.x, 0.62), y: opening.y + 7)
        let enter = tip.y > atIce.y ? tip : atIce
        var line = Path()
        line.move(to: tip)
        if descent > 17 {
            if tip.y < atIce.y {
                line.addQuadCurve(to: enter, control: CGPoint(x: tip.x + 8, y: blend(tip.y, enter.y, 0.6)))
            }
            line.addCurve(to: end,
                          control1: CGPoint(x: blend(enter.x, end.x, 0.23) - slack, y: enter.y + descent * 0.38),
                          control2: CGPoint(x: blend(enter.x, end.x, 0.8) + slack * 0.28, y: end.y - descent * 0.19))
        } else {
            line.addQuadCurve(to: end, control: CGPoint(x: (tip.x + end.x) / 2 - 8, y: max(tip.y, end.y) + 4))
        }
        ctx.stroke(line, with: .color(ink.opacity(0.62)), style: StrokeStyle(lineWidth: 3.9, lineCap: .round))
        let stress = bend > 0.83
        let bright = stress ? Color(red: 1, green: 0.78, blue: 0.55) : snow.opacity(0.89)
        let deep = bright.opacity(1 - clamp(descent / max(1, area.height)) * 0.29)
        ctx.stroke(line, with: .linearGradient(Gradient(colors: [bright, deep]), startPoint: tip, endPoint: end),
                   style: StrokeStyle(lineWidth: 1.45 + bend * 0.94, lineCap: .round))
    }

    func hookMark(_ ctx: GraphicsContext, point: CGPoint, scale: Double, strength: Double) {
        let d = 8 * scale
        let bead = CGRect(x: point.x - d * 0.50, y: point.y - d * 0.62, width: d, height: d * 1.12)
        ctx.fill(Path(ellipseIn: bead), with: .color(orange.opacity(max(0.52, strength))))
        var hook = Path()
        hook.move(to: point)
        hook.addQuadCurve(to: point.offset(x: d * 0.83, y: d * 0.78),
                          control: point.offset(x: -d * 0.13, y: d * 1.73))
        ctx.stroke(hook, with: .color(snow.opacity(max(0.52, strength))), lineWidth: 1.4)
    }

    func waterParticles(_ ctx: GraphicsContext, centre: CGPoint, age: Double,
                        scale: Double, landing: Bool, bait: CGPoint) {
        for i in 0..<(landing ? 23 : 15) {
            let n = Double(i)
            let t = max(0, age - Double(i % 5) * 0.038)
            let life = max(0, 1 - t / (landing ? 0.75 : 1.38))
            let side = i.isMultiple(of: 2) ? 1.0 : -1.0
            let velocities = Double(21 + i * 19 % 73) * scale
            let x: Double
            let y: Double
            if landing {
                x = centre.x + side * velocities * t * 1.6
                y = centre.y - velocities * t * 2.4 + 142 * t * t
            } else {
                x = blend(centre.x, bait.x, min(0.8, n / 20)) + side * (6 + t * velocities * 0.34)
                y = centre.y + 10 + n * scale * 7 - (23 + n * 2) * t - t * t * 13
            }
            if !landing && y < centre.y { continue }
            let radius = (1.15 + Double(i % 4) * 0.78) * scale * (0.85 + t * 0.44)
            let particle = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            if landing {
                ctx.fill(particle, with: .color(ice.opacity(life * 0.89)))
            } else {
                ctx.stroke(particle, with: .color(snow.opacity(life * 0.68)), lineWidth: 1.05)
            }
        }
        for i in 0..<3 {
            let t = smooth((age - Double(i) * 0.09) / 0.90)
            let rx = (9 + t * (landing ? 112 : 61)) * scale
            let ry = rx * 0.22
            let ring = CGRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2)
            ctx.stroke(Path(ellipseIn: ring), with: .color(snow.opacity((1 - t) * (landing ? 0.72 : 0.46))),
                       lineWidth: landing ? 1.7 : 1.15)
        }
    }

    func drawBeacon(_ ctx: GraphicsContext, at point: CGPoint, angle: Double, scale: Double, opacity: Double) {
        var local = ctx
        local.translateBy(x: point.x, y: point.y)
        local.rotate(by: .radians(sin(angle) * 0.20))
        local.opacity = opacity
        let shell = CGRect(x: -24 * scale, y: -18 * scale, width: 48 * scale, height: 36 * scale)
        local.fill(Path(roundedRect: shell, cornerRadius: 6), with: .color(orange))
        local.fill(Path(roundedRect: shell.insetBy(dx: 5, dy: 5), cornerRadius: 3), with: .color(ink))
        var antenna = Path()
        antenna.addLines([CGPoint(x: 11 * scale, y: -16 * scale), CGPoint(x: 30 * scale, y: -38 * scale)])
        local.stroke(antenna, with: .color(snow), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        let lamp = CGRect(x: -9 * scale, y: -4 * scale, width: 8 * scale, height: 8 * scale)
        local.fill(Path(ellipseIn: lamp), with: .color(orange.opacity(0.65 + beat * 0.35)))
    }

    func swimFish(_ ctx: GraphicsContext, centre: CGPoint, heading: Double, length: Double,
                  rhythm: Double, energy: Double, species: Int, opacity: Double) {
        var fish = ctx
        fish.translateBy(x: centre.x, y: centre.y)
        let facesLeft = cos(heading) < 0
        fish.rotate(by: .radians(facesLeft ? heading - .pi : heading))
        fish.scaleBy(x: facesLeft ? -1 : 1, y: 1)
        fish.opacity = opacity

        let backs: [Color] = [Color(red: 0.26, green: 0.35, blue: 0.13), gauge, Color(red: 0.42, green: 0.22, blue: 0.20),
                              Color(red: 0.27, green: 0.38, blue: 0.14), gauge, Color(red: 0.44, green: 0.33, blue: 0.20),
                              Color(red: 0.37, green: 0.25, blue: 0.17), Color(red: 0.35, green: 0.32, blue: 0.48)]
        let side: [Color] = [Color(red: 0.77, green: 0.83, blue: 0.47), ice, Color(red: 0.71, green: 0.45, blue: 0.25),
                             Color(red: 0.68, green: 0.76, blue: 0.42), snow, Color(red: 0.82, green: 0.60, blue: 0.36),
                             Color(red: 0.70, green: 0.51, blue: 0.29), Color(red: 0.56, green: 0.64, blue: 0.81)]
        let back = backs[species % backs.count]
        let belly = side[species % side.count]
        let widthScale = [0.15, 0.12, 0.15, 0.081, 0.16, 0.22, 0.11, 0.12][species % 8]

        func point(_ fromHead: Double, _ offset: Double) -> CGPoint {
            let x = length * (0.45 - fromHead)
            let flex = sin(rhythm - fromHead * 6.0) * length * 0.13 * fromHead * fromHead * energy
            return CGPoint(x: x, y: flex + offset * length)
        }
        let finSway = sin(rhythm + 0.6) * 0.033 * energy
        var tail = Path()
        tail.addLines([point(0.74, 0), point(0.99, -0.134 + finSway), point(0.94, 0.01),
                       point(1.01, 0.125 - finSway), point(0.76, 0.05)])
        tail.closeSubpath()
        fish.fill(tail, with: .color(back))
        fish.stroke(tail, with: .color(ice.opacity(0.35)), lineWidth: 0.7)

        var dorsal = Path()
        let crest = species == 7 ? -0.29 : -widthScale - 0.073
        dorsal.addLines([point(species == 3 ? 0.55 : 0.26, -widthScale * 0.72),
                         point(species == 3 ? 0.65 : 0.37, crest), point(0.51, crest * 0.83),
                         point(0.65, -widthScale * 0.7)])
        dorsal.closeSubpath()
        fish.fill(dorsal, with: .color(back))
        fish.stroke(dorsal, with: .color(ice.opacity(0.46)), lineWidth: 0.7)
        var body = Path()
        for i in 0...26 {
            let t = Double(i) * 0.81 / 26
            let spread = pow(sin(.pi * t / 0.83), 0.76) * widthScale
            if i == 0 { body.move(to: point(t, 0)) } else { body.addLine(to: point(t, -spread)) }
        }
        for i in (0...26).reversed() {
            let t = Double(i) * 0.81 / 26
            let spread = pow(sin(.pi * t / 0.83), 0.76) * widthScale
            body.addLine(to: point(t, spread * 0.78))
        }
        body.closeSubpath()
        fish.fill(body, with: .linearGradient(Gradient(colors: [back, belly, snow.opacity(0.91)]),
                                              startPoint: CGPoint(x: 0, y: -length * widthScale),
                                              endPoint: CGPoint(x: 0, y: length * widthScale)))
        var pattern = fish
        pattern.clip(to: body)
        if species == 0 {
            for i in 0..<6 {
                let t = 0.18 + Double(i) * 0.105
                var stripe = Path()
                stripe.addLines([point(t, -0.19), point(t + 0.055, -0.18),
                                 point(t + 0.023, 0.056), point(t - 0.012, 0.085)])
                stripe.closeSubpath()
                pattern.fill(stripe, with: .color(back.opacity(0.63)))
            }
        } else {
            for i in 0..<15 {
                let t = 0.21 + Double(i * 13 % 17) * 0.028
                let p = point(t, Double(i * 9 % 11) * 0.012 - 0.069)
                pattern.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 2.1, height: 1.65)),
                             with: .color(snow.opacity(0.51)))
            }
        }
        var fin = Path()
        fin.addLines([point(0.25, 0.04), point(0.44, 0.152 + finSway), point(0.47, 0.045)])
        fin.closeSubpath()
        fish.fill(fin, with: .color((species == 0 || species == 2 ? orange : back).opacity(0.83)))
        var gill = Path()
        gill.move(to: point(0.19, -widthScale * 0.57))
        gill.addQuadCurve(to: point(0.20, widthScale * 0.54), control: point(0.28, 0.008))
        fish.stroke(gill, with: .color(ink.opacity(0.64)), lineWidth: 0.9)
        let eye = point(0.10, -widthScale * 0.30)
        fish.fill(Path(ellipseIn: CGRect(x: eye.x - 2.6, y: eye.y - 2.6, width: 5.2, height: 5.2)), with: .color(ink))
        fish.fill(Path(ellipseIn: CGRect(x: eye.x - 0.1, y: eye.y - 1.7, width: 1.5, height: 1.5)), with: .color(snow))
    }
}

extension CGPoint {
    func offset(x: Double, y: Double) -> CGPoint { CGPoint(x: self.x + x, y: self.y + y) }
}

struct LakeBanner: View {
    var lake: Int

    var body: some View {
        ZStack {
            IceArt(seed: lake)
            Canvas { ctx, size in
                let points = lakeHoles[lake].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                var route = Path()
                route.addLines(points)
                ctx.stroke(route, with: .color(gauge), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                for (index, point) in points.enumerated() {
                    ctx.fill(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)),
                             with: .color(index == 0 ? orange : ink))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
}

struct FishPlate: View {
    var seed: Int
    private static let fishArtworkSize = CGSize(width: 370, height: 220)

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [ink, Color(red: 0.035, green: 0.12, blue: 0.17)]),
                                                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            for index in 1..<7 {
                let y = size.height * Double(index) / 7
                var line = Path()
                line.move(to: CGPoint(x: 12, y: y))
                line.addLine(to: CGPoint(x: size.width - 12, y: y))
                ctx.stroke(line, with: .color(ice.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
            }
            if seed == 8 {
                paintBeacon(ctx, size)
            } else if size.width > 0, size.height > 0 {
                let artworkSize = Self.fishArtworkSize
                let scale = min(size.width / artworkSize.width, size.height / artworkSize.height)
                let x = (size.width - artworkSize.width * scale) / 2
                let y = (size.height - artworkSize.height * scale) / 2
                var artwork = ctx
                artwork.translateBy(x: x, y: y)
                artwork.scaleBy(x: scale, y: scale)
                paintFish(artwork, artworkSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    func paintFish(_ ctx: GraphicsContext, _ size: CGSize) {
        let width = size.width * 0.83
        let height = size.height * 0.42
        let left = (size.width - width) / 2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: left + x * width, y: size.height * 0.53 + y * height)
        }

        let backs: [Color] = [
            Color(red: 0.44, green: 0.57, blue: 0.31),
            Color(red: 0.34, green: 0.58, blue: 0.64),
            Color(red: 0.54, green: 0.22, blue: 0.23),
            Color(red: 0.38, green: 0.49, blue: 0.26),
            Color(red: 0.46, green: 0.59, blue: 0.60),
            Color(red: 0.57, green: 0.44, blue: 0.27),
            Color(red: 0.45, green: 0.35, blue: 0.25),
            Color(red: 0.38, green: 0.34, blue: 0.65)
        ]
        let sides: [Color] = [
            Color(red: 0.77, green: 0.82, blue: 0.47), ice,
            Color(red: 0.90, green: 0.62, blue: 0.47),
            Color(red: 0.70, green: 0.73, blue: 0.43), snow,
            Color(red: 0.88, green: 0.70, blue: 0.44),
            Color(red: 0.72, green: 0.53, blue: 0.31),
            Color(red: 0.68, green: 0.77, blue: 0.82)
        ]
        let fin = [orange, gauge, orange, backs[3], orange, backs[5], backs[6], backs[7]][seed]
        let top = [-0.62, -0.43, -0.52, -0.29, -0.57, -0.77, -0.44, -0.38][seed]
        let belly = [0.49, 0.39, 0.43, 0.26, 0.53, 0.68, 0.38, 0.33][seed]
        let shoulder = [0.31, 0.37, 0.31, 0.37, 0.29, 0.26, 0.17, 0.33][seed]
        let mouth = seed == 3 ? 0.09 : 0.01
        let eyeX = seed == 3 ? 0.28 : seed == 6 ? 0.13 : 0.16

        var tail = Path()
        tail.move(to: point(0.73, -0.10))
        if seed == 6 {
            tail.addQuadCurve(to: point(0.98, -0.23), control: point(0.88, -0.36))
            tail.addQuadCurve(to: point(0.99, 0.22), control: point(1.03, -0.05))
            tail.addQuadCurve(to: point(0.74, 0.11), control: point(0.89, 0.37))
        } else {
            let fork = seed == 1 || seed == 4 || seed == 5
            tail.addQuadCurve(to: point(0.99, fork ? -0.47 : -0.36), control: point(0.87, -0.30))
            tail.addLine(to: point(fork ? 0.88 : 0.94, 0.01))
            tail.addLine(to: point(0.98, fork ? 0.47 : 0.36))
            tail.addQuadCurve(to: point(0.74, 0.10), control: point(0.85, 0.29))
        }
        tail.closeSubpath()
        ctx.fill(tail, with: .color(fin.opacity(0.86)))
        ctx.stroke(tail, with: .color(snow.opacity(0.52)), lineWidth: 1)
        for ray in -2...2 {
            var line = Path()
            line.addLines([point(0.79, 0.02), point(0.96, Double(ray) * 0.13)])
            ctx.stroke(line, with: .color(snow.opacity(0.30)), lineWidth: 0.65)
        }

        var dorsal = Path()
        switch seed {
        case 0:
            dorsal.addLines([point(0.24, -0.32), point(0.32, -0.82), point(0.35, -0.77), point(0.39, -0.91),
                             point(0.42, -0.80), point(0.46, -0.88), point(0.53, -0.64), point(0.58, -0.34)])
        case 3:
            dorsal.addLines([point(0.60, -0.20), point(0.69, -0.50), point(0.74, -0.52), point(0.82, -0.15)])
        case 6:
            dorsal.move(to: point(0.26, -0.24))
            dorsal.addQuadCurve(to: point(0.41, -0.27), control: point(0.32, -0.68))
            dorsal.addQuadCurve(to: point(0.83, -0.11), control: point(0.55, -0.63))
        case 7:
            dorsal.move(to: point(0.22, -0.22))
            dorsal.addQuadCurve(to: point(0.42, -1.05), control: point(0.30, -0.96))
            dorsal.addQuadCurve(to: point(0.70, -0.25), control: point(0.63, -0.91))
        default:
            dorsal.addLines([point(0.31, top * 0.64), point(0.40, top - 0.24),
                             point(0.50, top - 0.13), point(0.55, top * 0.43)])
        }
        dorsal.closeSubpath()
        ctx.fill(dorsal, with: .linearGradient(Gradient(colors: [backs[seed], fin.opacity(0.86)]),
                                               startPoint: point(0, -0.95), endPoint: point(0, 0)))
        ctx.stroke(dorsal, with: .color(snow.opacity(0.46)), lineWidth: 1)
        if seed == 7 {
            for i in 0..<8 {
                let t = Double(i)
                var ray = Path()
                ray.addLines([point(0.29 + t * 0.047, -0.30),
                              point(0.32 + t * 0.041, -0.72 - 0.29 * sin((t + 1) / 9 * .pi))])
                ctx.stroke(ray, with: .color(ice.opacity(0.55)), lineWidth: 0.9)
            }
        }

        let keel = seed == 5 ? 0.61 : 0.50
        var underFin = Path()
        underFin.addLines([point(keel - 0.15, belly * 0.57), point(keel + 0.01, belly + 0.26),
                           point(keel + 0.11, belly + 0.10), point(keel + 0.23, 0.16)])
        underFin.closeSubpath()
        ctx.fill(underFin, with: .color(fin.opacity(0.86)))
        ctx.stroke(underFin, with: .color(snow.opacity(0.42)), lineWidth: 1)

        var body = Path()
        body.move(to: point(0.018, mouth))
        if seed == 3 {
            body.addLine(to: point(0.005, -0.03))
            body.addLine(to: point(0.178, -0.12))
            body.addQuadCurve(to: point(0.35, top), control: point(0.27, -0.37))
        } else {
            body.addQuadCurve(to: point(shoulder, top), control: point(0.10, top * 0.97))
        }
        body.addCurve(to: point(0.80, -0.12), control1: point(shoulder + 0.15, top - 0.05),
                      control2: point(0.69, top * 0.5))
        body.addQuadCurve(to: point(0.81, 0.12), control: point(0.824, 0))
        body.addQuadCurve(to: point(shoulder + 0.13, belly), control: point(0.67, belly * 0.92))
        body.addQuadCurve(to: point(0.015, mouth), control: point(0.13, belly * 1.02))
        body.closeSubpath()

        ctx.fill(body, with: .linearGradient(Gradient(colors: [backs[seed], sides[seed], snow]),
                                             startPoint: point(0, top), endPoint: point(0, belly * 1.19)))
        var scales = ctx
        scales.clip(to: body)
        for i in 0..<160 {
            let x = 0.06 + Double((i * 73 + seed * 11) % 137) / 137 * 0.75
            let y = Double((i * i * 17 + i * 9) % 127) / 127 - 0.53
            let p = point(x, y)
            let radius = (i % 5 == 0 ? 1.4 : 0.65) * max(0.75, size.height / 180)
            scales.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: radius * 1.7, height: radius)),
                        with: .color(i % 3 == 0 ? ink.opacity(0.17) : snow.opacity(0.38)))
        }
        if seed == 0 {
            for i in 0..<6 {
                let x = 0.23 + Double(i) * 0.087
                var bar = Path()
                bar.addLines([point(x - 0.03, -0.69), point(x + 0.032, -0.64),
                              point(x + 0.046, 0.28), point(x + 0.012, 0.18)])
                bar.closeSubpath()
                scales.fill(bar, with: .color(ink.opacity(0.48)))
            }
        }
        if seed == 2 || seed == 3 || seed == 6 {
            for i in 0..<36 {
                let x = 0.21 + Double((i * 29 + seed * 7) % 61) / 100
                let y = Double((i * i * 13 + 7) % 47) / 88 - 0.33
                let p = point(x, y)
                let r = max(1, size.height * (0.009 + Double(i % 3) * 0.004))
                let colour = seed == 6 ? backs[seed] : seed == 2 ? Color(red: 0.98, green: 0.76, blue: 0.54) : snow
                scales.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r * (seed == 6 ? 2.8 : 1.6), height: r)),
                            with: .color(colour.opacity(0.82)))
            }
        }
        if seed == 4 || seed == 7 {
            var ribbon = Path()
            ribbon.move(to: point(0.20, 0.02))
            ribbon.addQuadCurve(to: point(0.82, 0), control: point(0.53, 0.28))
            scales.stroke(ribbon, with: .color(seed == 7 ? fin.opacity(0.65) : gauge.opacity(0.62)),
                          lineWidth: seed == 7 ? 4 : 1.5)
        }
        ctx.stroke(body, with: .color(snow.opacity(0.76)), lineWidth: 1)
        var gill = Path()
        gill.move(to: point(eyeX + 0.025, top * 0.53))
        gill.addQuadCurve(to: point(eyeX + 0.066, belly * 0.67), control: point(eyeX + 0.16, -0.015))
        ctx.stroke(gill, with: .color(ink.opacity(0.74)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        var pectoral = Path()
        pectoral.move(to: point(eyeX + 0.09, 0.12))
        pectoral.addQuadCurve(to: point(eyeX + 0.25, 0.38), control: point(eyeX + 0.18, 0.06))
        pectoral.addQuadCurve(to: point(eyeX + 0.09, 0.12), control: point(eyeX + 0.17, 0.39))
        ctx.fill(pectoral, with: .color(fin.opacity(0.81)))

        let eye = point(eyeX, seed == 3 ? -0.13 : -0.14)
        let r = max(2.8, size.height * 0.023)
        ctx.fill(Path(ellipseIn: CGRect(x: eye.x - r, y: eye.y - r, width: r * 2, height: r * 2)), with: .color(ink))
        ctx.fill(Path(ellipseIn: CGRect(x: eye.x - 0.34 * r, y: eye.y - 0.52 * r, width: r * 0.55, height: r * 0.55)),
                 with: .color(snow))
        var jaw = Path()
        jaw.move(to: point(0.018, mouth))
        jaw.addQuadCurve(to: point(seed == 3 ? 0.23 : 0.105, mouth + 0.04), control: point(0.072, mouth - 0.026))
        if seed == 6 {
            jaw.move(to: point(0.070, 0.24))
            jaw.addQuadCurve(to: point(0.056, 0.53), control: point(0.083, 0.46))
        }
        ctx.stroke(jaw, with: .color(ink.opacity(0.92)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    func paintBeacon(_ ctx: GraphicsContext, _ size: CGSize) {
        let u = min(size.width, size.height) / 230
        let mid = CGPoint(x: size.width / 2, y: size.height * 0.55)
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: mid.x + x * u, y: mid.y + y * u) }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ radius: Double) -> Path {
            Path(roundedRect: CGRect(origin: p(x, y), size: CGSize(width: w * u, height: h * u)),
                 cornerRadius: radius * u)
        }
        let yellow = Color(red: 1, green: 0.65, blue: 0.29)
        let brown = Color(red: 0.59, green: 0.23, blue: 0.10)
        let teal = Color(red: 0.23, green: 0.48, blue: 0.55)
        for i in 0..<4 {
            let r = Double(i) * 14
            ctx.stroke(Path(ellipseIn: CGRect(origin: p(-67 - r, 53 - r / 6),
                                              size: CGSize(width: (132 + r * 2) * u, height: (15 + r * 0.54) * u))),
                       with: .color(ice.opacity(0.46 - Double(i) * 0.085)), lineWidth: max(1, u))
        }

        var pole = Path()
        pole.addLines([p(43, -38), p(58, -66), p(80, -87)])
        ctx.stroke(pole, with: .color(ink), style: StrokeStyle(lineWidth: 9 * u, lineCap: .round))
        ctx.stroke(pole, with: .color(snow), style: StrokeStyle(lineWidth: 4 * u, lineCap: .round))
        ctx.fill(box(76, -93, 10, 10, 5), with: .color(orange))
        var handle = Path()
        handle.move(to: p(-29, -45))
        handle.addQuadCurve(to: p(21, -44), control: p(-5, -86))
        ctx.stroke(handle, with: .color(ink), style: StrokeStyle(lineWidth: 10 * u, lineCap: .round))
        ctx.stroke(handle, with: .color(orange), style: StrokeStyle(lineWidth: 6 * u, lineCap: .round))
        let shell = box(-55, -44, 111, 99, 15)
        ctx.fill(box(-55, -39, 118, 98, 17), with: .color(brown))
        ctx.fill(shell, with: .linearGradient(Gradient(colors: [yellow, orange, brown]),
                                             startPoint: p(-48, -52), endPoint: p(37, 59)))
        ctx.stroke(shell, with: .color(snow.opacity(0.64)), lineWidth: 1.7 * u)
        ctx.fill(box(-46, -34, 90, 72, 10), with: .color(ink))
        ctx.stroke(box(-46, -34, 90, 72, 10), with: .color(brown), lineWidth: 3 * u)
        ctx.fill(box(-36, -25, 43, 21, 4), with: .color(teal))
        ctx.stroke(box(-36, -25, 43, 21, 4), with: .color(ice.opacity(0.77)), lineWidth: 1.1 * u)
        var wave = Path()
        wave.addLines([p(-31, -14), p(-24, -14), p(-21, -20), p(-16, -10), p(-12, -14),
                       p(-6, -14), p(-3, -19), p(0, -14), p(3, -14)])
        ctx.stroke(wave, with: .color(snow), style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round))
        ctx.fill(box(18, -23, 13, 13, 7), with: .color(orange))
        ctx.fill(box(20, -21, 9, 9, 5), with: .color(yellow))
        for y in 0..<4 {
            for x in 0..<8 {
                let slot = box(-34 + Double(x) * 9.1, 5 + Double(y) * 6.4, 5, 2.2, 1)
                ctx.fill(slot, with: .color(gauge))
            }
        }
        for (x, y) in [(-49.0, -32.0), (43, -32), (-49, 40), (43, 40)] {
            ctx.fill(box(x, y, 6.5, 6.5, 3.25), with: .color(ink))
            ctx.stroke(box(x, y, 6.5, 6.5, 3.25), with: .color(yellow.opacity(0.7)), lineWidth: u)
        }
        for i in 0..<8 {
            let x = Double((i * 43) % 149) - 73
            let y = 38 + Double(i % 4) * 11
            var drip = Path()
            drip.addLines([p(x, y), p(x - 2, y + 8)])
            ctx.stroke(drip, with: .color(ice.opacity(0.62)), style: StrokeStyle(lineWidth: 1.6 * u, lineCap: .round))
        }
    }
}
