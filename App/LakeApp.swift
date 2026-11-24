import SwiftUI

let ink = Color(red: 0.078, green: 0.204, blue: 0.259)
let ice = Color(red: 0.867, green: 0.933, blue: 0.941)
let orange = Color(red: 0.925, green: 0.447, blue: 0.184)
let gauge = Color(red: 0.325, green: 0.435, blue: 0.447)
let snow = Color(red: 0.973, green: 0.980, blue: 0.949)

@main
struct LakeApp: App {
    @StateObject private var game: LakeGame
    @StateObject private var radio = LakeRadio()

    init() {
        var defaults = UserDefaults.standard
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--qa-save"), args.indices.contains(index + 1) {
            let domain = "local.factory.icefishingfm.qa." + args[index + 1]
            defaults = UserDefaults(suiteName: domain)!
            if args.contains("--qa-reset") {
                defaults.removePersistentDomain(forName: domain)
                if let fixture = ProcessInfo.processInfo.environment["ICEFISH_QA_SAVE"],
                   let data = Data(base64Encoded: fixture) {
                    defaults.set(data, forKey: "expedition.v1")
                }
            }
        }
        #endif
        _game = StateObject(wrappedValue: LakeGame(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            ExpeditionView(game: game, radio: radio)
                .preferredColorScheme(.light)
                .tint(ink)
        }
    }
}

func caption(_ text: String) -> some View {
    Text(text).font(.system(.caption, design: .monospaced, weight: .semibold))
        .tracking(1.3)
}

struct FieldButton: View {
    var text: String
    var icon: String? = nil
    var filled = false
    var large = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon) }
                Text(text).multilineTextAlignment(.center)
            }
            .font(.system(large ? .headline : .subheadline, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, large ? 12 : 8)
            .frame(maxWidth: .infinity, minHeight: large ? 55 : 44)
            .foregroundStyle(filled ? snow : ink)
            .background(filled ? ink : snow, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.18)) }
        }
        .buttonStyle(.plain)
    }
}

struct ExpeditionView: View {
    @ObservedObject var game: LakeGame
    @ObservedObject var radio: LakeRadio
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @State private var receiverOpen = true
    @State private var page = "field"
    @State private var preview: String?
    @State private var showGuide = false

    var body: some View {
        GeometryReader { proxy in
            if page == "field" && game.trip.phase != "filed" && game.trip.phase != "landed" {
                playField(size: proxy.size)
            } else {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        Group {
                            switch page {
                            case "map": mapPage
                            case "journal": journalPage
                            default: returned(width: proxy.size.width, height: proxy.size.height)
                            }
                        }
                        .frame(maxWidth: 1150)
                        .padding(.horizontal, proxy.size.width >= 690 ? 26 : 16)
                        .padding(.top, 15)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity)
                    }
                    .id(page)
                    tabs
                }
            }
        }
        .foregroundStyle(ink)
        .background(ice.ignoresSafeArea())
        .overlay {
            if radio.interrupted {
                ZStack {
                    ink.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 6) {
                        Image(systemName: "pause.circle").font(.largeTitle)
                        Text(tr("Audio interrupted")).font(.headline)
                        Text(tr("The expedition will resume when audio returns.")).font(.callout)
                    }
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .background(snow, in: RoundedRectangle(cornerRadius: 16))
                    .padding(24)
                }
            }
        }
        .onChange(of: signal, initial: true) { _, signal in radio.play(signal) }
        .onChange(of: scene, initial: true) { _, scene in radio.setActive(scene == .active) }
        .onChange(of: game.book.muted, initial: true) { _, muted in radio.setMuted(muted) }
        .sheet(isPresented: $showGuide) { guide }
    }

    var signal: Signal? {
        if let preview, page == "journal" || (page == "field" && game.trip.phase == "filed") {
            return .clean(game.campaign.profile(preview))
        }
        guard page == "field", !showGuide else { return nil }
        if game.trip.phase == "bite" { return .clean(game.campaign.profile(game.level.source)) }
        guard game.trip.phase == "listen", let reading = game.live else { return nil }
        return Signal.reading(reading, game.campaign, noise: game.level.noise)
    }

    var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 42, height: 38)
                    .background(orange, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(ink)
                Text("Ice Fishing FM")
                    .font(.system(size: 23, weight: .black, design: .serif))
                    .foregroundStyle(snow)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button {
                game.book.muted.toggle()
            } label: {
                Image(systemName: game.book.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(snow)
                    .frame(width: 44, height: 44)
                    .background(snow.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(game.book.muted ? tr("Enable sound") : tr("Mute sound"))
            .accessibilityIdentifier("sound")
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 8)
        .background(ink, ignoresSafeAreaEdges: [])
    }

    var tabs: some View {
        HStack(spacing: 2) {
            tab("map", "Expeditions", "map")
            tab("field", "On the ice", "dot.scope")
            tab("journal", "Journal", "book.closed")
        }
        .padding(.horizontal, 13)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .background(snow.ignoresSafeArea(edges: .bottom))
    }

    func tab(_ id: String, _ title: String, _ icon: String) -> some View {
        Button {
            preview = nil
            page = id
        } label: {
            Label(tr(title), systemImage: icon)
                .font(.system(.caption, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(page == id ? snow : ink)
                .background(page == id ? ink : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-" + id)
        .accessibilityAddTraits(page == id ? .isSelected : [])
    }

    func playField(size: CGSize) -> some View {
        let side = size.width >= 690
        let fieldPad: CGFloat = side ? 18 : 10
        let panelWidth = min(395, max(310, size.width * 0.33))
        let phoneDock: CGFloat = game.level.moving ? 388 : 334
        let iceLeft = side && direction == .rightToLeft ? panelWidth + fieldPad * 2 : fieldPad
        let iceArea = CGRect(x: iceLeft, y: 77,
                             width: side ? size.width - panelWidth - fieldPad * 3 : size.width - fieldPad * 2,
                             height: max(155, size.height - 77 - (side ? 37 : phoneDock)))
        let waterArea = CGRect(x: 0, y: 94, width: size.width,
                               height: max(170, size.height - 312))
        let survey = game.trip.phase == "listen"
        return ZStack(alignment: .top) {
            if survey {
                IceMap(game: game, radio: radio, area: iceArea)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(width: size.width, height: size.height)
            } else {
                WaterStage(game: game, radio: radio, area: waterArea, wide: side,
                           awake: scene == .active && !radio.interrupted && !showGuide)
                    .frame(width: size.width, height: size.height)
            }

            VStack(spacing: 0) {
                fieldHUD(side: side)
                    .padding(.horizontal, fieldPad)
                    .padding(.top, 5)

                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                if survey {
                    HStack(spacing: 0) {
                        if side { Spacer(minLength: 0).allowsHitTesting(false) }
                        if receiverOpen {
                            VStack(spacing: 6) {
                                ReceiverPanel(game: game, radio: radio,
                                              fieldHeight: side ? min(530, size.height * 0.48) : nil,
                                              toggle: flipReceiver)
                                if !game.trip.pins.isEmpty { recordings(side: side) }
                            }
                            .frame(maxWidth: side ? panelWidth : .infinity)
                            .transition(.move(edge: side ? .trailing : .bottom).combined(with: .opacity))
                        } else {
                            restoredReceiver
                        }
                    }
                    .padding(.horizontal, fieldPad)
                }
            }
            .padding(.bottom, 8)
        }
    }

    func flipReceiver() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.23)) {
            receiverOpen.toggle()
        }
    }

    func fieldHUD(side: Bool) -> some View {
        HStack(spacing: side ? 8 : 3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(lakeKeys[game.level.lake]))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .lineLimit(1)
                Text(game.level.title)
                    .font(.system(size: side ? 24 : 20, weight: .black, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                    .accessibilityIdentifier("expedition-title")
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(snow, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 1)
            fieldIcon("tab-map", "Expeditions", "map") {
                preview = nil
                page = "map"
            }
            fieldIcon("tab-journal", "Journal", "book.closed") {
                preview = nil
                page = "journal"
            }
            fieldIcon("guide", "Field guide", "questionmark") { showGuide = true }
            fieldIcon("sound", game.book.muted ? "Enable sound" : "Mute sound",
                      game.book.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { game.book.muted.toggle() }
        }
    }

    func fieldIcon(_ id: String, _ name: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(snow)
                .background(ink, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(name))
        .accessibilityIdentifier(id)
    }

    var restoredReceiver: some View {
        Button(action: flipReceiver) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                Text(tr("Hydrophone"))
                if let reading = game.live {
                    Text(levelText(reading.strength)).monospacedDigit()
                }
                Image(systemName: "chevron.up")
            }
            .font(.system(.subheadline, weight: .bold))
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .foregroundStyle(ink)
            .background(orange, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Show receiver"))
        .accessibilityIdentifier("receiver-drawer")
        .padding(.horizontal, 14)
    }

    func recordings(side: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(game.trip.pins) { row in
                recording(row, side: side)
            }
        }
        .padding(.horizontal, 6)
    }

    func recording(_ row: Reading, side: Bool) -> some View {
        let hole = holeName(row.hole)
        let strength = levelText(row.strength)
        let accessibilityText = [label("Hole %@", hole), row.time, tr(depthKeys[row.depth]), strength]
            .joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: ["circle.fill", "triangle.fill", "diamond.fill"][row.id % 3])
                    .font(.system(size: 7, weight: .black))
                Text(hole).fontWeight(.heavy)
                Spacer(minLength: 0)
                Text(strength).fontWeight(.bold)
            }
            HStack(spacing: 3) {
                Text(row.time).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: row.depth == 0 ? "water.waves" : "arrow.down")
            }
            SignalTape(signal: .reading(row, game.campaign, noise: game.level.noise), phase: nil)
                .frame(height: 15)
                .background(ink, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
        .font(side ? .caption : .caption2)
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(snow, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("pin-\(row.id)")
    }

    func returned(width: CGFloat, height: CGFloat) -> some View {
        let wide = width >= 690
        return VStack(alignment: .leading, spacing: wide ? 18 : 10) {
            VStack(alignment: .leading, spacing: 2) {
                caption(tr(lakeKeys[game.level.lake]))
                Text(game.level.title)
                    .font(.system(size: wide ? 43 : 34, weight: .black, design: .serif))
                    .accessibilityIdentifier("expedition-title")
                    .accessibilityAddTraits(.isHeader)
            }
            returnPanel(wide: wide, height: height)
        }
    }

    func returnPanel(wide: Bool, height: CGFloat) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 20))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
        let illustration = game.campaign.fish.firstIndex { $0.id == game.level.source } ?? 0
        return layout {
            FishPlate(seed: game.level.id == "broadcast" ? 8 : illustration)
                .frame(height: wide ? min(710, max(350, height * 0.58)) : 220)
                .frame(maxWidth: .infinity)
            catchCard(wide: wide)
                .frame(maxWidth: wide ? 325 : .infinity)
        }
    }

    func catchCard(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 17 : 14) {
            Text(game.level.id == "broadcast" ? tr("Training beacon recovered") : game.campaign.profile(game.level.source).name)
                .font(wide ? .system(size: 43, weight: .black, design: .serif)
                           : .system(.largeTitle, design: .serif, weight: .black))
                .accessibilityIdentifier("catch-title")
            Text(tr("note." + (game.level.survey == nil ? game.level.id : "survey")))
                .font(wide ? .title3 : .body)
                .fixedSize(horizontal: false, vertical: true)
            if game.trip.phase == "landed" {
                FieldButton(text: tr("Paste into journal"), icon: "book.closed", filled: true, large: wide) { game.fileCatch() }
                    .accessibilityIdentifier("file")
            } else {
                if game.level.id == "double" && game.campaign.fish.contains(where: { $0.id == "whitefish" }) {
                    FieldButton(text: tr(preview == "whitefish" ? "Stop recording" : "Play the three notes"),
                                icon: preview == "whitefish" ? "stop.fill" : "play.fill", large: wide) {
                        preview = preview == "whitefish" ? nil : "whitefish"
                    }
                    if preview == "whitefish" {
                        LiveTape(radio: radio).frame(height: 42).background(ink, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                FieldButton(text: tr("Open journal"), icon: "book.closed", large: wide) {
                    preview = nil
                    page = "journal"
                }
                FieldButton(text: tr("Expeditions"), icon: "map", filled: true, large: wide) {
                    preview = nil
                    page = "map"
                }
            }
        }
        .padding(wide ? 21 : 0)
        .background(wide ? snow : Color.clear, in: RoundedRectangle(cornerRadius: 16))
    }

    var mapPage: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(tr("Expeditions")).font(.system(.largeTitle, design: .serif, weight: .black))
            ForEach(lakeKeys.indices, id: \.self) { lake in
                VStack(alignment: .leading, spacing: 8) {
                    LakeBanner(lake: lake).frame(height: 105)
                    Text(tr(lakeKeys[lake])).font(.system(.title2, design: .serif, weight: .black))
                    ForEach(game.campaign.levels.indices.filter { game.campaign.levels[$0].lake == lake }, id: \.self) { index in
                        let task = game.campaign.levels[index]
                        let current = task.id == game.trip.id
                        let done = game.book.completed.contains(task.id)
                        let open = game.available(index) && !done
                        FieldButton(text: current && !done ? label("Resume %@", task.title) : task.title,
                                    icon: done ? "checkmark" : open ? "arrow.right" : "lock",
                                    filled: open) {
                            preview = nil
                            game.open(task.id)
                            receiverOpen = true
                            page = "field"
                        }
                        .disabled(!open)
                        .opacity(open || done ? 1 : 0.5)
                        .accessibilityIdentifier("task-" + task.id)
                    }
                    if game.finalised {
                        FieldButton(text: tr("Free survey"), icon: "location") {
                            preview = nil
                            game.open("survey-\(lake)")
                            receiverOpen = true
                            page = "field"
                        }
                        .accessibilityIdentifier("survey-\(lake)")
                    }
                }
                .padding(11).background(snow, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    var journalPage: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr("Field journal")).font(.system(.largeTitle, design: .serif, weight: .black))
            if game.book.catches.isEmpty {
                Text(tr("Land a catch to add its silhouette and recording."))
            }
            if !game.book.fragments.isEmpty { beaconPage }
            ForEach(game.campaign.fish.filter { profile in
                game.book.catches.contains { $0.fish == profile.id }
            }) { profile in
                let entries = game.book.catches.filter { $0.fish == profile.id }
                VStack(alignment: .leading, spacing: 7) {
                    FishPlate(seed: game.campaign.profiles.firstIndex { $0.id == profile.id } ?? 0)
                        .frame(height: 95)
                    Text(profile.name).font(.system(.title2, design: .serif, weight: .heavy))
                    Text(profile.pattern).font(.callout)
                    ForEach(entries) { entry in
                        Text(label("%@ · Hole %@", tr(lakeKeys[entry.lake]), holeName(entry.hole)))
                            .font(.caption.monospaced())
                        Text(tr("note." + (entry.task.hasPrefix("survey-") ? "survey" : entry.task)))
                            .font(.footnote)
                    }
                    FieldButton(text: tr(preview == profile.id ? "Stop recording" : "Play recording"),
                                icon: preview == profile.id ? "stop.fill" : "play.fill") {
                        preview = preview == profile.id ? nil : profile.id
                    }
                    .accessibilityIdentifier("play-" + profile.id)
                    if preview == profile.id {
                        LiveTape(radio: radio).frame(height: 45)
                            .background(ink, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        SignalTape(signal: .clean(profile), phase: nil).frame(height: 38)
                            .background(ink, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10).background(snow, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    var beaconPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption(tr("Training beacon"))
            Text(tr("Match the end of each phrase to the start of the next. Begin with the count-in."))
                .font(.callout)
            ForEach(game.book.fragments.sorted(), id: \.self) { piece in
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("phrase." + piece)).font(.callout.monospaced())
                    HStack {
                        FieldButton(text: tr(preview == piece ? "Stop recording" : "Play phrase"),
                                    icon: preview == piece ? "stop.fill" : "play.fill") {
                            preview = preview == piece ? nil : piece
                        }
                        .accessibilityIdentifier("play-" + piece)
                        FieldButton(text: label("Place %@", tr("piece." + piece)), icon: "plus") {
                            game.addPhrase(piece)
                        }
                        .disabled(game.book.sequence.contains(piece) || game.book.fragments.count < 3)
                        .accessibilityIdentifier("phrase-" + piece)
                    }
                    if preview == piece {
                        LiveTape(radio: radio).frame(height: 42)
                            .background(ink, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if game.book.fragments.count == 3 {
                if !game.book.sequence.isEmpty {
                    Text(game.book.sequence.map { tr("piece." + $0) }.joined(separator: "  →  "))
                        .font(.callout.monospaced().bold())
                }
                if game.aligned {
                    Text(tr("Signal joined. Tune channel 4, listen deep, then lift at the strongest hole."))
                        .font(.callout.bold())
                        .accessibilityIdentifier("joined")
                } else if game.book.sequence.count == 3 {
                    Text(tr("The joins do not match. Clear the order and compare the phrase ends."))
                        .font(.callout)
                        .accessibilityIdentifier("bad-order")
                }
                if !game.book.sequence.isEmpty {
                    FieldButton(text: tr("Clear order"), icon: "arrow.counterclockwise") { game.book.sequence = [] }
                        .accessibilityIdentifier("clear-order")
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(snow, in: RoundedRectangle(cornerRadius: 12))
    }

    var guide: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.level.title).font(.system(.title2, design: .serif, weight: .black))
                        Text(tr("brief." + (game.level.survey == nil ? game.level.id : "survey")))
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(snow, in: RoundedRectangle(cornerRadius: 10))
                    ForEach(game.campaign.fish) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.name).font(.system(.title3, design: .serif, weight: .heavy))
                            Text(profile.pattern)
                            Text(label("%@ · %@", tr(depthKeys[profile.depth]), tr(lureKeys[profile.lure])))
                            Text(label("Loop %@ s · taps %@ s", String(format: "%.2f", profile.loop),
                                       profile.beats.map { String(format: "%.2f", $0) }.joined(separator: " / ")))
                                .font(.caption.monospaced())
                            Text(label("Pauses %@ s", zip(profile.beats.dropFirst(), profile.beats)
                                .map { String(format: "%.2f", $0 - $1) }.joined(separator: " / ")))
                                .font(.caption.monospaced())
                            SignalTape(signal: .clean(profile), phase: nil)
                                .frame(height: 33).background(ink, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(snow, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(14)
            }
            .background(ice)
            .navigationTitle(tr("Field guide"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { showGuide = false }.accessibilityIdentifier("guide-done")
                }
            }
        }
        .foregroundStyle(ink)
    }
}
