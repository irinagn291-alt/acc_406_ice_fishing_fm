import XCTest

final class ExpeditionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func photo(_ name: String) {
        Thread.sleep(forTimeInterval: 0.22)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func tap(_ app: XCUIApplication, _ id: String) {
        let element = find(app, id)
        if !element.exists { XCTAssertTrue(element.waitForExistence(timeout: 5), id) }
        for _ in 0..<7 {
            if element.isHittable { break }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { break }
            if element.frame.midY < scroll.frame.midY { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.isHittable, id)
        element.tap()
    }

    func compareAndCatch(_ app: XCUIApplication, prefix: String, useDrag: Bool) {
        XCTAssertTrue(find(app, "expedition-title").waitForExistence(timeout: 6))
        XCTAssertEqual(find(app, "expedition-title").label, "Double Knock")
        if useDrag {
            photo(prefix + "-clean")
            dragProbe(app, to: "hole-0")
            XCTAssertEqual(find(app, "live-strength").label, "49%")
        } else {
            tap(app, "hole-0")
        }
        let rough = find(app, "live-clarity").value as? String
        tap(app, "tune-up")
        XCTAssertEqual(rough, "68%")
        XCTAssertEqual(find(app, "live-clarity").value as? String, "94%")
        tap(app, "pin")
        if useDrag { dragProbe(app, to: "hole-1") } else { tap(app, "hole-1") }
        XCTAssertEqual(find(app, "live-strength").label, "94%")
        tap(app, "pin")
        XCTAssertTrue(find(app, "pin-0").label.contains("49%"))
        XCTAssertTrue(find(app, "pin-1").label.contains("94%"))
        XCTAssertTrue(find(app, "pin-0").label.contains("06:00"))
        XCTAssertTrue(find(app, "pin-1").label.contains("06:00"))
        photo(prefix + "-comparison")
        tap(app, "rig")
        tap(app, "depth-1")
        tap(app, "drop")
        expectDiagnostic(app, "Pass above the hook. Try the shallows.")
        Thread.sleep(forTimeInterval: 0.95)
        photo(prefix + "-depth-miss")
        tap(app, "depth-0")
        tap(app, "drop")
        XCTAssertTrue(find(app, "strike").waitForExistence(timeout: 5))
        photo(prefix + "-bite")
        strike(app)
        land(app, prefix: prefix)
        XCTAssertEqual(find(app, "catch-title").label, "Glass perch")
        tap(app, "file")
        photo(prefix + "-filed")
    }

    func dragProbe(_ app: XCUIApplication, to hole: String) {
        let handle = find(app, "hydrophone").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let target = find(app, hole).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        handle.press(forDuration: 0.12, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.13)
    }

    func expectDiagnostic(_ app: XCUIApplication, _ expected: String) {
        let feedback = find(app, "diagnostic")
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), expected)
        XCTAssertEqual(feedback.label, expected)
    }

    func readPercent(_ element: XCUIElement) -> Int {
        let text = [element.label, String(describing: element.value ?? "")]
        for candidate in text {
            if let digits = Int(candidate.filter(\.isNumber)) { return digits }
        }
        XCTFail("No percentage for \(element.identifier), \(text)")
        return -1
    }

    func land(_ app: XCUIApplication, prefix: String? = nil, verifyLoad: Bool = true) {
        let reel = find(app, "reel")
        let ease = find(app, "ease")
        let tension = find(app, "tension")
        XCTAssertTrue(reel.waitForExistence(timeout: 4))
        for move in 0..<7 {
            if !reel.exists || !reel.isEnabled { break }
            let before = readPercent(find(app, "winding"))
            reel.press(forDuration: move == 0 ? 0.80 : 0.71)
            if move == 0 && verifyLoad {
                let after = readPercent(find(app, "winding"))
                let loaded = readPercent(tension)
                XCTAssertGreaterThan(after, before, "Holding the reel must wind the line")
                if let prefix { photo(prefix + "-tension") }
                ease.press(forDuration: 0.46)
                XCTAssertLessThan(readPercent(tension), loaded, "Feeding line must release load")
            } else if ease.exists && ease.isEnabled {
                ease.press(forDuration: 0.41)
            }
        }
        if let prefix {
            let onIce = find(app, "catch-on-ice")
            XCTAssertTrue(onIce.waitForExistence(timeout: 3), "The fish settles on the ice before filing")
            photo(prefix + "-on-ice")
        }
        XCTAssertTrue(find(app, "file").waitForExistence(timeout: 5), "Bring the hooked fish through the ice")
    }

    func strike(_ app: XCUIApplication) {
        let button = find(app, "strike")
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 8), .completed)
        tap(app, "strike")
    }

    func seeded(_ name: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-save", name, "--qa-reset"]
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json",
                                                          subdirectory: "Fixtures"))
        app.launchEnvironment["ICEFISH_QA_SAVE"] = try Data(contentsOf: url).base64EncodedString()
        app.launch()
        return app
    }

    func test01CleanFirstExpedition() {
        let app = XCUIApplication()
        app.launchArguments = ["--capture-audio"]
        app.launch()
        compareAndCatch(app, prefix: "first", useDrag: true)
        Thread.sleep(forTimeInterval: 0.55)
        tap(app, "tab-journal")
        XCTAssertTrue(find(app, "play-perch").exists)
        photo("first-journal")
    }

    func test02MutedFirstExpedition() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-save", "muted", "--qa-reset"]
        app.launch()
        tap(app, "sound")
        XCTAssertEqual(find(app, "sound").label, "Enable sound")
        compareAndCatch(app, prefix: "muted", useDrag: false)
    }

    func test03TimedRouteAndResume() throws {
        let app = try seeded("pass")
        XCTAssertEqual(find(app, "expedition-title").label, "On the Pass")
        tap(app, "depth-1")
        tap(app, "hole-0")
        tap(app, "tune-up")
        tap(app, "tune-up")
        tap(app, "pin")
        tap(app, "rig")
        tap(app, "drop")
        expectDiagnostic(app, "Pin strong readings at two different stops before predicting the next.")
        tap(app, "back-readings")
        tap(app, "wait")
        tap(app, "hole-1")
        tap(app, "pin")
        XCTAssertTrue(find(app, "pin-0").label.contains("06:00"))
        XCTAssertTrue(find(app, "pin-1").label.contains("06:01"))
        if !find(app, "pin-1").isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        photo("reeds-timed-readings")
        tap(app, "hole-2")
        tap(app, "rig")
        tap(app, "lure-2")
        app.terminate()
        app.launchArguments = ["--qa-save", "pass"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertEqual(find(app, "expedition-title").label, "On the Pass")
        XCTAssertTrue(find(app, "drop").exists)
        photo("reeds-restored-rig")
        tap(app, "back-readings")
        XCTAssertTrue(find(app, "pin-1").label.contains("06:01"))
        tap(app, "tab-journal")
        XCTAssertTrue(find(app, "play-clock").exists)
        XCTAssertTrue(find(app, "play-perch").exists)
        tap(app, "play-clock")
        photo("reeds-restored-journal")
        tap(app, "tab-field")
        tap(app, "rig")
        tap(app, "drop")
        XCTAssertTrue(find(app, "strike").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(find(app, "strike").exists)
        strike(app)
        find(app, "reel").press(forDuration: 0.55)
        let wound = readPercent(find(app, "winding"))
        XCTAssertGreaterThan(wound, 0)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertGreaterThanOrEqual(readPercent(find(app, "winding")), wound)
        Thread.sleep(forTimeInterval: 0.45)
        photo("reeds-tension-after-background")
        find(app, "ease").press(forDuration: 0.45)
        land(app, verifyLoad: false)
        XCTAssertEqual(find(app, "catch-title").label, "Reed pike")
        tap(app, "file")
        photo("reeds-catch")
    }

    func test04BeaconMatchAndRecover() throws {
        let app = try seeded("broadcast")
        tap(app, "tab-journal")
        for id in ["tail", "clock", "pair"] { tap(app, "phrase-" + id) }
        XCTAssertTrue(find(app, "bad-order").exists)
        photo("pier-rejected-phrase-order")
        tap(app, "clear-order")
        for id in ["clock", "pair", "tail"] { tap(app, "phrase-" + id) }
        XCTAssertTrue(find(app, "joined").exists)
        photo("pier-joined-phrases")
        tap(app, "tab-field")
        tap(app, "depth-1")
        tap(app, "tune-up")
        tap(app, "tune-up")
        tap(app, "hole-2")
        tap(app, "pin")
        let other = find(app, "live-strength").label
        tap(app, "hole-3")
        XCTAssertEqual(find(app, "live-strength").label, "94%")
        XCTAssertNotEqual(other, "94%")
        tap(app, "pin")
        if !find(app, "pin-1").isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        photo("pier-beacon-readings")
        tap(app, "rig")
        tap(app, "drop")
        strike(app)
        land(app)
        XCTAssertEqual(find(app, "catch-title").label, "Training beacon recovered")
        tap(app, "file")
        photo("pier-beacon-recovered")
        tap(app, "tab-map")
        XCTAssertTrue(find(app, "survey-0").exists)
        XCTAssertTrue(find(app, "survey-1").exists)
        XCTAssertTrue(find(app, "survey-2").exists)
        tap(app, "survey-0")
        XCTAssertEqual(find(app, "expedition-title").label, "Free survey")
    }

    func test05LocalisedLaunches() {
        let app = XCUIApplication()
        for (lang, locale, title) in [
            ("en-GB", "en_GB", "Double Knock"),
            ("en-US", "en_US", "Double Knock"),
            ("zh-Hant", "zh_TW", "雙叩"),
            ("ar", "ar_SA", "طرقتان")
        ] {
            app.launchArguments = ["--qa-save", lang, "--qa-reset", "-AppleLanguages", "(\(lang))",
                                   "-AppleLocale", locale]
            app.launch()
            XCTAssertEqual(find(app, "expedition-title").label, title, lang)
            tap(app, "hole-1")
            photo("locale-" + lang)
            app.terminate()
        }
    }

    func test06AllFishRecordings() throws {
        let app = try seeded("broadcast")
        tap(app, "tab-journal")
        for id in ["perch", "whitefish", "char", "pike", "roach", "bream", "burbot", "grayling"] {
            tap(app, "play-" + id)
            XCTAssertEqual(find(app, "play-" + id).label, "Stop recording")
        }
        photo("journal-ribbon-grayling-playing")
    }

    func test07FreshCampaign() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-save", "full-campaign", "--qa-reset"]
        app.launch()

        // Each row is a route followed using the same controls available to a player.
        let tasks: [(id: String, title: String, catchName: String, tune: Int, depth: Int,
                     lure: Int, route: [Int], timed: Bool)] = [
            ("double", "Double Knock", "Glass perch", 2, 0, 0, [1], false),
            ("third", "Third Voice", "Snow whitefish", 1, 0, 2, [2], false),
            ("ledge", "The Ledge", "Ember char", 0, 1, 1, [0], false),
            ("copper", "Copper Note", "Copper bream", 3, 1, 1, [2], false),
            ("pass", "On the Pass", "Reed pike", 3, 1, 2, [0, 1, 2, 3], true),
            ("hollow", "Hollow Echo", "Ember char", 2, 1, 1, [2], false),
            ("schools", "Two Schools", "Silver roach", 4, 0, 0, [1, 2, 3], false),
            ("phrase", "Second Phrase", "Copper bream", 0, 1, 1, [3, 2, 1, 0], true),
            ("deep", "Deep Water", "Night burbot", 4, 1, 2, [2], false),
            ("tangle", "Crossed Traces", "Ribbon grayling", 2, 0, 1, [0, 2, 4], false),
            ("quiet", "Quiet Circle", "Night burbot", 1, 1, 2, [4, 3, 2, 1, 0], true),
            ("broadcast", "Last Broadcast", "Training beacon recovered", 3, 1, 0, [3], false),
        ]

        for (index, task) in tasks.enumerated() {
            if index > 0 {
                tap(app, "tab-map")
                tap(app, "task-" + task.id)
            }
            let title = find(app, "expedition-title").label
            if task.id == "schools" {
                XCTAssertTrue(["Two Schools", "Two Shoals"].contains(title))
            } else {
                XCTAssertEqual(title, task.title)
            }
            if task.id == "broadcast" {
                tap(app, "tab-journal")
                for piece in ["clock", "pair", "tail"] { tap(app, "phrase-" + piece) }
                XCTAssertTrue(find(app, "joined").exists)
                photo("campaign-joined-phrases")
                tap(app, "tab-field")
            }

            for _ in 0..<abs(task.tune - 1) { tap(app, task.tune > 1 ? "tune-up" : "tune-down") }
            if task.id == "hollow" || task.id == "copper" {
                tap(app, "hole-0")
                tap(app, "pin")
            }
            if task.id == "schools" || task.id == "tangle" {
                tap(app, "depth-1")
                tap(app, "hole-\(task.route[0])")
                tap(app, "pin")
            }
            tap(app, "depth-\(task.depth)")

            var arrival = task.route[0]
            if task.timed {
                tap(app, "hole-\(task.route[0])")
                tap(app, "pin")
                tap(app, "wait")
                tap(app, "hole-\(task.route[1])")
                tap(app, "pin")
                arrival = task.route[2]
            } else if task.route.count > 1 {
                arrival = task.route[1]
            } else if task.id == "broadcast" || task.id == "double" {
                tap(app, task.id == "broadcast" ? "hole-2" : "hole-0")
                tap(app, "pin")
            }

            tap(app, "hole-\(arrival)")
            if !task.timed { tap(app, "pin") }
            tap(app, "rig")
            if task.id != "broadcast" { tap(app, "lure-\(task.lure)") }
            tap(app, "drop")
            strike(app)
            land(app, verifyLoad: false)
            XCTAssertEqual(find(app, "catch-title").label, task.catchName)
            tap(app, "file")
            XCTAssertFalse(find(app, "file").exists)
            print("CAMPAIGN UI \(index + 1)/12 \(task.id): \(task.catchName) filed")
            if [0, 3, 7, 10, 11].contains(index) { photo("campaign-filed-" + task.id) }
        }

        app.terminate()
        app.launchArguments = ["--qa-save", "full-campaign"]
        app.launch()
        XCTAssertEqual(find(app, "catch-title").label, "Training beacon recovered")
        photo("campaign-final-after-relaunch")
        tap(app, "tab-map")
        XCTAssertTrue(find(app, "survey-0").exists)
        XCTAssertTrue(find(app, "survey-1").exists)
        XCTAssertTrue(find(app, "survey-2").exists)
        tap(app, "survey-0")
        XCTAssertEqual(find(app, "expedition-title").label, "Free survey")
        photo("campaign-survey-unlocked")
    }

    func measureIce(_ app: XCUIApplication, prefix: String) {
        let ids = ["hole-0", "hole-1", "hole-2", "hydrophone"]
        let frames = ids.map { find(app, $0).frame }
        let centres = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
        for (id, frame) in zip(ids, frames) {
            XCTAssertGreaterThanOrEqual(frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(frame.height, 44, id)
            XCTAssertTrue(app.frame.contains(frame), id)
        }
        for id in ["tab-map", "tab-journal", "sound", "guide", "tune-up", "tune-down"] {
            let frame = find(app, id).frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(frame.height, 44, id)
        }
        let width = centres.map(\.x).max()! - centres.map(\.x).min()!
        let height = centres.map(\.y).max()! - centres.map(\.y).min()!
        print("ACTIVE ICE \(prefix) \(Int(app.frame.width))x\(Int(app.frame.height)) stage centres \(Int(width.rounded()))x\(Int(height.rounded())) pt")
    }

    func test08LandscapeFieldAndReel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-save", "landscape", "--qa-reset"]
        app.launch()
        guard app.frame.width >= 690 else { throw XCTSkip("iPhone supports portrait in this project") }
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
        compareAndCatch(app, prefix: "landscape", useDrag: true)
    }

    func test09OverloadLeavesASecondCast() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa-save", "overload", "--qa-reset"]
        app.launch()
        tap(app, "hole-1")
        tap(app, "rig")
        tap(app, "drop")
        strike(app)
        find(app, "reel").press(forDuration: 2.3)
        expectDiagnostic(app, "The line pulled tight. The source slipped free.")
        tap(app, "drop")
        strike(app)
        land(app)
        XCTAssertEqual(find(app, "catch-title").label, "Glass perch")
    }
}
