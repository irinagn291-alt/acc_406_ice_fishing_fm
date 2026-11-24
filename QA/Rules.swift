import Foundation

@main
struct Rules {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    static func fight(_ game: LakeGame, careless: Bool = false) {
        var motion = FightMotion()
        let dt = 1.0 / 60
        for frame in 0..<480 {
            let stroke = frame % 83
            let hand: LineHand = careless || stroke < 47 ? .wind : .ease
            motion.advance(dt, hand: hand, depth: game.trip.depth, lake: game.level.lake,
                           anchored: game.level.id == "broadcast")
            if motion.failed || motion.lift >= 2.34 { break }
        }
        check(careless ? motion.failed : motion.arrived && motion.lift >= 2.34,
              "continuous tension/landing " + game.level.id)
        game.rememberFight(motion.memory)
        game.finishFight(landed: !motion.failed)
    }

    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let campaign = try JSONDecoder().decode(Campaign.self, from: Data(contentsOf: input))
        let suite = "local.factory.icefishingfm.rules." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let game = LakeGame(defaults: defaults, campaign: campaign)

        check(campaign.levels.count == 12, "campaign count")
        check(campaign.fish.count == 8, "fish count")
        check(Set(campaign.fish.map { $0.beats }).count == 8, "distinct rhythmic figures")
        check(Set(campaign.fish.map { Signal.clean($0).wav() }).count == 8, "distinct recorded PCM")
        check(Set(campaign.fish.map { $0.lure }).count == 3, "lure coverage")
        check(Set(campaign.fish.map { $0.depth }).count == 2, "depth coverage")
        check(Set(campaign.levels.compactMap { $0.fragment }) == Set(fragmentIDs), "fragment coverage")
        for profile in campaign.profiles {
            check(profile.beats.count == profile.notes.count, "complete motif " + profile.id)
            check(profile.beats == profile.beats.sorted() && profile.beats.last! + 0.10 < profile.loop,
                  "valid timing " + profile.id)
        }

        for (index, level) in campaign.levels.enumerated() {
            let fish = campaign.profile(level.source)
            check(game.available(index), "campaign order " + level.id)
            if index + 1 < campaign.levels.count {
                check(!game.available(index + 1), "gating " + level.id)
            }
            game.open(level.id)
            if level.id == "pass" || level.id == "broadcast" {
                let fixture = output.appendingPathComponent("fixture-" + level.id + ".json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(game.book).write(to: fixture)
            }
            game.tune(level.tune)
            game.setDepth(fish.depth)
            game.setLure(fish.lure)
            if level.id == "double" {
                game.select(0)
                let weak = Signal.reading(game.live!, campaign, noise: level.noise)
                game.pin()
                check(weak == Signal.reading(game.live!, campaign, noise: level.noise), "pin changed sound")
                check(game.live!.minute == 0, "stationary clock")
                game.rig()
                game.drop()
                check(game.trip.phase == "rig" && game.trip.feedback.hasPrefix("Weak echo") &&
                      game.trip.pins.count == 1, "wrong hole leaves a weak-echo diagnostic and the pin")
                game.listen()
                game.select(1)
                let strong = Signal.reading(game.live!, campaign, noise: level.noise)
                check(weak.pulses == strong.pulses && weak.strength < strong.strength, "same motif, different distance")
                check(strong.pulses.allSatisfy { pulse in
                    strong.amplitude(pulse.time + 0.025) > weak.amplitude(pulse.time + 0.025)
                }, "visual peaks track signal")
                check(strong.wav() != weak.wav(), "audio amplitude tracks signal")
                try weak.wav().write(to: output.appendingPathComponent("01-hole-A.wav"))
                try strong.wav().write(to: output.appendingPathComponent("02-hole-B.wav"))
                game.pin()
                game.rig()
                game.setDepth(1)
                game.drop()
                check(game.trip.phase == "rig" && game.trip.feedback.hasPrefix("Pass above"), "depth diagnosis")
                check(game.trip.pins.count == 2 && game.trip.minute == 0, "stationary retry preserves evidence")
                game.setDepth(0)
                game.setLure(1)
                game.drop()
                check(game.trip.feedback.hasPrefix("Interest"), "lure diagnosis")
                game.setLure(0)
                game.listen()
            }
            if level.id == "third" {
                check(level.route.count == 1 && game.target(0) == game.target(12), "repeatable second expedition")
                game.select(level.route[0])
                let triple = Signal.reading(game.live!, campaign, noise: level.noise)
                check(triple.pulses.count == 3, "three notes on second route")
                try triple.wav().write(to: output.appendingPathComponent("03-third-voice.wav"))
            }
            if let fake = level.echo {
                game.setDepth(1 - fish.depth)
                game.select(fake)
                check(game.live?.sources == ["echo"], "depth reveals mechanical echo")
                game.setDepth(fish.depth)
                check(game.live?.sources.contains(fish.id) == true, "live target after filtering")
            }
            if let rival = level.rival {
                game.select(level.route[0])
                game.setDepth(campaign.profile(rival).depth)
                check(game.live!.sources.contains(rival), "rival overlaps")
                game.setDepth(fish.depth)
                check(!game.live!.sources.contains(rival), "depth isolates target")
            }
            if level.timed == true {
                game.select(game.target(0))
                game.pin()
                game.rig()
                game.drop()
                check(game.trip.feedback.hasPrefix("Pin strong"), "one timestamp rejected")
                game.listen()
                game.waitMinute()
                game.select(game.target(1))
                game.pin()
                check(game.timeEvidence, "position and time corroboration")
            }
            if level.id == "broadcast" {
                check(game.book.fragments.count == 3, "missing story phrases")
                game.select(game.target(0))
                game.rig()
                game.drop()
                check(game.trip.feedback.hasPrefix("Join"), "unjoined phrases rejected")
                game.listen()
                for piece in fragmentIDs.reversed() { game.addPhrase(piece) }
                check(!game.aligned, "wrong match")
                game.book.sequence = []
                for piece in fragmentIDs { game.addPhrase(piece) }
                check(game.aligned, "ordered phrase match")
                game.select((game.target(0) + 1) % lakeHoles[level.lake].count)
                game.pin()
                game.select(game.target(0))
                game.pin()
            }
            game.select(game.target(game.trip.minute + (level.moving ? 1 : 0)))
            game.rig()
            game.drop()
            check(game.trip.phase == "bite", "valid drop " + level.id)
            game.strike()
            if level.id == "double" {
                let memory = FightMemory(winding: 0.24, load: 0.70)
                game.rememberFight(memory)
                let active = LakeGame(defaults: defaults, campaign: campaign)
                check(active.trip.phase == "fight" && active.trip.fight?.winding == 0.24 &&
                      active.trip.fight?.load == 0.70, "continual load and winding persist")
                var legacy = game.book
                legacy.trip.fight = nil
                legacy.trip.strokes = 2
                defaults.set(try JSONEncoder().encode(legacy), forKey: "expedition.v1")
                let migrated = LakeGame(defaults: defaults, campaign: campaign)
                check(migrated.trip.fight?.winding == 0.44, "old active fight migrates")
                fight(game, careless: true)
                check(game.trip.phase == "rig" && game.trip.pins.count == 2, "lost line preserves evidence")
                game.drop()
                game.strike()
            }
            fight(game)
            check(game.trip.phase == "landed", "landed " + level.id)
            game.fileCatch()
            let recorded = game.book.completed.count
            game.fileCatch()
            check(recorded == index + 1 && game.book.completed.count == recorded, "idempotent journal")
            let restored = LakeGame(defaults: defaults, campaign: campaign)
            check(restored.trip.phase == "filed" && restored.trip.id == level.id &&
                  restored.book.fragments == game.book.fragments && restored.book.catches.count == game.book.catches.count,
                  "saved journal " + level.id)
            print("PASS \(index + 1)/12 \(level.id): locate, rig, strike, land, file, reload")
        }
        check(Set(game.book.catches.map(\.fish)).count == 8, "all fish discoverable")
        check(game.finalised, "free surveys unlocked")
        for lake in lakeKeys.indices {
            game.open("survey-\(lake)")
            let source = game.level.source
            let route = game.level.route
            let fish = campaign.profile(source)
            game.select(game.target(0))
            game.tune(game.level.tune)
            game.setDepth(fish.depth)
            game.setLure(fish.lure)
            let before = game.live!
            for _ in 0..<4 { game.pin() }
            let after = game.live!
            check(before.hole == after.hole && before.minute == after.minute &&
                  before.strength == after.strength && before.sources == after.sources, "pins move no survey source")
            check(game.trip.pins.count == 3, "last three readings")
            game.waitMinute()
            check(game.level.source == source && game.level.route == route && game.target(1) != game.target(0),
                  "survey movement changes stop and keeps source")
            let resumed = LakeGame(defaults: defaults, campaign: campaign)
            check(resumed.level.source == source && resumed.level.route == route &&
                  resumed.trip.depth == fish.depth && resumed.trip.lure == fish.lure &&
                  resumed.trip.tune == game.trip.tune && resumed.trip.pins.count == 3, "resume survey")
            game.select(game.target(2))
            game.rig()
            game.drop()
            game.strike()
            fight(game)
            game.fileCatch()
            check(game.level.source != source && game.level.route != route && game.trip.minute == 0, "next survey")
            print("PASS free survey \(lake + 1)/3: stable source, timed movement, pin cap, persistence, rotation")
        }
        print("PASS three distinct diagnostics, shared signal envelope and fixed first two routes")
        print("PASS 8 distinguishable fish motifs, 3 phrases, 3 lures, 2 depths")
        for cue in WaterCue.allCases {
            try cue.wav().write(to: output.appendingPathComponent("cue-" + cue.rawValue + ".wav"))
        }
    }
}
