// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class ReleaseNotesTests: XCTestCase {
    /// The real v0.3.0 body, verbatim. The parser's input is prose written by hand months
    /// apart, so the fixture is a released artefact rather than something shaped to pass.
    private let realBody = """
    MacRazer now starts at login and installs its own updates, with Settings and About windows to go with them.

    > **This is the first release you can install from inside the app** — and the first time that path has run on a machine other than the developer's. If an update ever misbehaves, the DMG below always works.

    ### Added
    - **Start MacRazer at login**, on by default. A menu bar battery meter that stops existing after every reboot isn't much of a battery meter.
    - **"Update & Restart"** in the update card. When a new version is out, MacRazer downloads it with a progress bar.
    - **A Settings window** (right-click the menu bar icon › Settings…, or the gear in the popover footer): start at login, show battery % in the menu bar, automatic updates, and what version you're on with a Check Now button.
    - The **charging bolt fills the mouse icon and is yellow**, instead of a grey squiggle you had to look for.

    ### Fixed
    - Builds no longer appear to hang at the codesigning step. macOS was showing a keychain prompt that a scripted build has nobody to click.

    ### Install
    This build is unsigned (no paid Apple Developer ID), so first launch shows the standard Gatekeeper warning.

    **Full changelog:** https://github.com/SorcRR/MacRazer/blob/master/CHANGELOG.md
    """

    func testKeepsTheSectionsWorthReading() {
        let notes = ReleaseNotes.parse(realBody)
        XCTAssertEqual(notes.sections.map(\.title), ["Added", "Fixed"],
                       "Install is for someone who hasn't got the app running yet")
        XCTAssertEqual(notes.sections[0].items.count, 4)
        XCTAssertEqual(notes.sections[1].items.count, 1)
    }

    func testSummaryKeepsTheCalloutButNotItsMarkers() {
        let notes = ReleaseNotes.parse(realBody)
        XCTAssertTrue(notes.summary.hasPrefix("MacRazer now starts at login"))
        XCTAssertTrue(notes.summary.contains("first release you can install from inside the app"))
        XCTAssertFalse(notes.summary.contains(">"), "blockquote marker")
        XCTAssertFalse(notes.summary.contains("**"), "bold markers")
    }

    func testDropsTheChangelogFooter() {
        let notes = ReleaseNotes.parse(realBody)
        let all = notes.summary + notes.sections.flatMap(\.items).map { $0.headline + $0.detail }.joined()
        XCTAssertFalse(all.contains("Full changelog"))
        XCTAssertFalse(all.contains("github.com"))
    }

    // MARK: - The four bullet shapes the real notes actually use

    func testBoldLeadBecomesTheHeadline() {
        let i = ReleaseNotes.item(from: "**Start MacRazer at login**, on by default. A menu bar battery meter that stops existing isn't much of one.")
        XCTAssertEqual(i.headline, "Start MacRazer at login")
        XCTAssertEqual(i.detail, "on by default. A menu bar battery meter that stops existing isn't much of one.")
    }

    func testQuotedFeatureNameSurvives() {
        let i = ReleaseNotes.item(from: "**\"Update & Restart\"** in the update card. It downloads with a progress bar.")
        XCTAssertEqual(i.headline, "\"Update & Restart\"")
        XCTAssertEqual(i.detail, "in the update card. It downloads with a progress bar.")
    }

    func testNoEmphasisFallsBackToTheFirstSentence() {
        let i = ReleaseNotes.item(from: "Builds no longer appear to hang at the codesigning step. macOS was showing a keychain prompt.")
        XCTAssertEqual(i.headline, "Builds no longer appear to hang at the codesigning step.")
        XCTAssertEqual(i.detail, "macOS was showing a keychain prompt.")
    }

    func testMidSentenceBoldIsNotMistakenForALead() {
        // The bold run starts partway in, so the first sentence is the honest lead.
        let i = ReleaseNotes.item(from: "The **charging bolt fills the mouse icon and is yellow**, instead of a grey squiggle.")
        XCTAssertFalse(i.headline.hasPrefix("charging bolt"), "must not lift the middle of the sentence")
        XCTAssertTrue((i.headline + i.detail).contains("charging bolt fills the mouse icon"))
    }

    func testAnOverlongLeadIsLeftWhole() {
        // The Settings-window bullet: one sentence, far too long to set apart as a headline.
        let long = "**A Settings window** (right-click the menu bar icon › Settings…, or the gear in the popover footer): start at login, show battery % in the menu bar, automatic updates, and what version you're on with a Check Now button."
        let i = ReleaseNotes.item(from: long)
        XCTAssertEqual(i.headline, "A Settings window")
        XCTAssertTrue(i.detail.contains("Check Now button"), "nothing may be dropped")
    }

    func testNothingIsEverSilentlyLost() {
        // Whatever the shape, every bullet's words reach the reader somewhere.
        for bullet in ["plain sentence with no punctuation at all",
                       "**bold only**",
                       "A `code` span and a [link](https://example.com) inline.",
                       ""] {
            let i = ReleaseNotes.item(from: bullet)
            let out = (i.headline + " " + i.detail).trimmingCharacters(in: .whitespaces)
            let expected = ReleaseNotes.strip(bullet)
            XCTAssertFalse(out.isEmpty && !expected.isEmpty, "dropped: '\(bullet)'")
        }
    }

    func testTheDashAfterABoldLeadGoesWithIt() {
        let i = ReleaseNotes.item(from: "**Orochi 2013** — verified over Bluetooth.")
        XCTAssertEqual(i.headline, "Orochi 2013")
        XCTAssertEqual(i.detail, "verified over Bluetooth.")
    }

    func testMarkdownMarkersAreStripped() {
        XCTAssertEqual(ReleaseNotes.strip("a **bold** and `code`"), "a bold and code")
        XCTAssertEqual(ReleaseNotes.strip("see [the docs](https://example.com) here"), "see the docs here")
    }

    func testAStrayBracketDoesNotSwallowTheTextAfterIt() {
        // Pairing the first `[` with the first later `](` destroyed everything between them.
        // Release bodies now carry changelog prose verbatim, and that prose has brackets in it.
        XCTAssertEqual(ReleaseNotes.strip("a [ b [c](https://e.com)"), "a [ b c")
        XCTAssertEqual(ReleaseNotes.strip("an unclosed [ bracket"), "an unclosed [ bracket")
        XCTAssertEqual(ReleaseNotes.strip("two [one](https://a.com) and [two](https://b.com)"),
                       "two one and two")
    }

    // MARK: Prose the body wraps, and prose that isn't the summary

    func testAWrappedSummaryIsOneParagraph() {
        // Every markdown file in this repo is hard-wrapped and the drafted template wraps too,
        // so a summary split across source lines is the normal case, not an edge one. Joining
        // them with a paragraph break put a blank line through the middle of a sentence.
        let notes = ReleaseNotes.parse("""
        MacRazer now starts at login and installs its own updates, with Settings
        and About windows to go with them.

        ### Added
        - **A thing.** Yes.
        """)
        XCTAssertEqual(notes.summary,
                       "MacRazer now starts at login and installs its own updates, with Settings and About windows to go with them.")
    }

    func testABlankLineStillStartsANewParagraph() {
        let notes = ReleaseNotes.parse("""
        First paragraph, wrapped
        across two lines.

        > A callout after a blank line.

        ### Added
        - **A thing.** Yes.
        """)
        XCTAssertEqual(notes.summary, "First paragraph, wrapped across two lines.\n\nA callout after a blank line.")
    }

    func testProseAfterTheBulletsStaysOutOfTheSummary() {
        // Reachable since a body with no headings at all became supported: the summary branch
        // used to accept any non-bullet line while no heading had been seen, which hoisted a
        // closing sentence to the top of the page, above the bullets it was written under.
        let notes = ReleaseNotes.parse("""
        - first thing
        - second thing
        See the README for details.
        """)
        XCTAssertEqual(notes.summary, "")
        XCTAssertEqual(notes.sections.first?.items.count, 2)
    }

    // MARK: Shapes a future release body could arrive in

    func testGeneratedNotesUseHashHashAndAsterisks() {
        // What GitHub's "Generate release notes" button emits. Nothing in the app forces the
        // hand-written style, and a body whose headings and bullets all went unrecognised
        // would arrive as one undifferentiated paragraph.
        let notes = ReleaseNotes.parse("""
        ## What's Changed
        * Fix the brightness slider by @someone in #21
        * Add two mice by @other in #22
        """)
        XCTAssertEqual(notes.sections.count, 1)
        XCTAssertEqual(notes.sections.first?.title, "What's Changed")
        XCTAssertEqual(notes.sections.first?.items.count, 2)
    }

    func testAListWithNoHeadingIsStillShown() {
        let notes = ReleaseNotes.parse("""
        - **First thing.** It happened.
        - **Second thing.** So did this.
        """)
        XCTAssertEqual(notes.sections.count, 1)
        XCTAssertEqual(notes.sections.first?.title, "")
        // The period is inside the bold run, so it stays with the headline — the parser
        // reports the author's emphasis rather than re-punctuating it.
        XCTAssertEqual(notes.sections.first?.items.map(\.headline), ["First thing.", "Second thing."])
    }

    func testAWrappedBulletKeepsItsSecondHalf() {
        let notes = ReleaseNotes.parse("""
        ### Fixed
        - **Brightness on scroll-wheel mice.** The LED group was hardcoded,
          so the slider silently did nothing.
        """)
        XCTAssertEqual(notes.sections.first?.items.count, 1)
        XCTAssertEqual(notes.sections.first?.items.first?.detail,
                       "The LED group was hardcoded, so the slider silently did nothing.")
    }

    func testAParagraphAfterABlankLineIsNotGluedOntoTheBullet() {
        let notes = ReleaseNotes.parse("""
        ### Added
        - **A thing.** It does something.

        See the README for the details.
        """)
        XCTAssertEqual(notes.sections.first?.items.count, 1)
        XCTAssertEqual(notes.sections.first?.items.first?.detail, "It does something.")
    }

    /// The two halves have to agree: `Scripts/release-notes.sh` decides the shape of every
    /// future release body, and this decides what that shape turns into on screen. They are a
    /// shell script and a Swift struct with no compiler between them, so the agreement is only
    /// as good as a test that states it.
    func testTheShapeReleaseNotesShDraftsParsesAsIntended() {
        let drafted = """
        MacRazer now starts at login and installs its own updates.

        ### Added
        - **A new thing.** It does something.

        ### Thanks
        - **@caseyc** — Add support for the thing (#5)

        ### Install
        This build is unsigned (no paid Apple Developer ID), so first launch shows the standard
        Gatekeeper warning.

        **Full changelog:** https://github.com/SorcRR/MacRazer/blob/master/CHANGELOG.md
        """
        let notes = ReleaseNotes.parse(drafted)
        XCTAssertEqual(notes.summary, "MacRazer now starts at login and installs its own updates.")
        XCTAssertEqual(notes.sections.map(\.title), ["Added", "Thanks"])
        // Contributors are credited in the app, not only on the releases page.
        XCTAssertEqual(notes.sections.last?.items.first?.headline, "@caseyc")
        XCTAssertEqual(notes.sections.last?.items.first?.detail, "Add support for the thing (#5)")
    }

    func testEmptyBodyIsEmptyNotACrash() {
        XCTAssertTrue(ReleaseNotes.parse("").isEmpty)
        XCTAssertTrue(ReleaseNotes.parse("\n\n").isEmpty)
    }
}
