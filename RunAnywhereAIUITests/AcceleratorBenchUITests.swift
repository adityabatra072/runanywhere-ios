//
//  AcceleratorBenchUITests.swift
//  RunAnywhereAIUITests
//
//  Opens the Accelerator Bench screen and proves the views actually render.
//
//  The integration tests call `AcceleratorBenchRunner` directly, which means
//  they exercise every measurement path and NONE of the UI. A broken chart, a
//  metric grid that clips, a nav link that never appears — all of that passes
//  those tests silently. This is the pass that would catch it, and it captures
//  a screenshot at each step so the screen can be reviewed without a device in
//  hand.
//
//  macOS only by default: iOS free provisioning caps dev-signed apps at three
//  per device, and the UITest runner is a second app.
//

import XCTest

final class AcceleratorBenchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Navigation

    func testBenchScreenOpensAndRenders() throws {
        attach(name: "01-launch")

        try openAdvanced()
        attach(name: "02-advanced-hub")

        // The row this feature added. If it is missing, the nav wiring is wrong
        // and nothing else in the demo is reachable.
        let row = firstMatch(labelled: "Accelerator Bench")
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "no 'Accelerator Bench' row in Advanced — nav link is not wired.\n"
                + describeTree()
        )
        row.click()

        // The screen's own title, to confirm we landed rather than no-oped.
        let title = app.staticTexts["Accelerator Bench"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "bench screen did not appear")
        attach(name: "03-bench-ask-mode")

        // Mode picker: three segments, each of which must be selectable.
        for mode in ["Ask", "Contention", "Endurance"] {
            let segment = firstMatch(labelled: mode)
            XCTAssertTrue(
                segment.waitForExistence(timeout: 5),
                "mode '\(mode)' missing from the picker.\n" + describeTree()
            )
            segment.click()
            attach(name: "04-mode-\(mode.lowercased())")
        }

        // Back to Ask, which is the mode the demo opens on.
        firstMatch(labelled: "Ask").click()

        // The provenance section is the honesty copy; it must be on screen.
        XCTAssertTrue(
            app.staticTexts["Host CPU is not accelerator energy"].exists
                || !app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS 'accelerator energy'")
                ).isEmpty,
            "the host-CPU caveat is not rendered — a number could be read as energy"
        )
    }

    // MARK: - Settings sheet

    func testSettingsSheetOpensAndCarriesItsReasoning() throws {
        try openAdvanced()
        let row = firstMatch(labelled: "Accelerator Bench")
        guard row.waitForExistence(timeout: 10) else {
            XCTFail("bench row missing.\n" + describeTree())
            return
        }
        row.click()
        XCTAssertTrue(app.staticTexts["Accelerator Bench"].waitForExistence(timeout: 10))

        let settings = app.buttons["Bench settings"]
        XCTAssertTrue(
            settings.waitForExistence(timeout: 5),
            "no settings button.\n" + describeTree()
        )
        settings.click()

        let ranking = firstMatch(labelled: "Rank contenders by throughput")
        XCTAssertTrue(
            ranking.waitForExistence(timeout: 5),
            "the throughput-ranking toggle is missing.\n" + describeTree()
        )
        attach(name: "05-settings-sheet")

        // Off by default is a deliberate choice, not a default that drifted.
        if let value = ranking.value as? String {
            XCTAssertEqual(value, "0", "throughput ranking must default to OFF")
        }

        firstMatch(labelled: "Done").click()
    }

    // MARK: - Helpers

    /// Reach the Advanced hub. ⌘3 is published by the shell; fall back to
    /// clicking the sidebar row when the key equivalent does not land.
    private func openAdvanced() throws {
        app.typeKey("3", modifierFlags: .command)
        if firstMatch(labelled: "Accelerator Bench").waitForExistence(timeout: 5) { return }

        for candidate in ["Advanced", "More"] {
            let row = firstMatch(labelled: candidate)
            if row.exists {
                row.click()
                if firstMatch(labelled: "Accelerator Bench").waitForExistence(timeout: 5) { return }
            }
        }
        XCTFail("could not reach the Advanced hub.\n" + describeTree())
    }

    /// First hittable element carrying `label`, across the element types this
    /// screen uses. Queried by label rather than identifier because the views
    /// ship no accessibility identifiers.
    private func firstMatch(labelled label: String) -> XCUIElement {
        for query in [app.buttons, app.staticTexts, app.radioButtons, app.switches, app.cells] {
            let element = query[label]
            if element.exists { return element }
        }
        return app.buttons[label]
    }

    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Dumped into failure messages so a missing element can be diagnosed
    /// without re-running blind.
    private func describeTree() -> String {
        String(app.debugDescription.prefix(4000))
    }
}
