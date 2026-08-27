import XCTest
@testable import CoteDOs

/// The renderer that stands in for Templater when Obsidian isn't the one
/// creating the note.
final class DailyNoteTemplateTests: XCTestCase {

    private let day = DateComponents(calendar: .current, year: 2026, month: 8, day: 13).date!

    // MARK: Rendering

    func testRendersTemplaterDateAndTitle() {
        let rendered = DailyNoteTemplate.render(
            """
            created: <% tp.date.now("YYYY-MM-DD", 0, tp.file.title, "YYYY-MM-DD") %>
            # <% tp.file.title %>
            """,
            date: day, title: "2026-08-13")
        XCTAssertEqual(rendered, "created: 2026-08-13\n# 2026-08-13")
    }

    func testAppliesDayOffset() {
        let rendered = DailyNoteTemplate.render(
            "![[01-daily/<% tp.date.now(\"YYYY-MM-DD\", -1, tp.file.title, \"YYYY-MM-DD\") %>#Plan]]",
            date: day, title: "2026-08-13")
        XCTAssertEqual(rendered, "![[01-daily/2026-08-12#Plan]]")
    }

    func testTomorrowAndYesterday() {
        XCTAssertEqual(
            DailyNoteTemplate.render("<% tp.date.tomorrow(\"YYYY-MM-DD\") %>", date: day, title: "x"),
            "2026-08-14")
        XCTAssertEqual(
            DailyNoteTemplate.render("<% tp.date.yesterday(\"YYYY-MM-DD\") %>", date: day, title: "x"),
            "2026-08-12")
    }

    func testWeekdayNameUsesTheSystemLanguage() {
        let rendered = DailyNoteTemplate.render("<% tp.date.now(\"dddd\") %>", date: day, title: "x")
        let expected = DateFormatter()
        expected.locale = Locale.current
        expected.dateFormat = "EEEE"
        XCTAssertEqual(rendered, expected.string(from: day))
        XCTAssertFalse(rendered.contains("<%"))
    }

    func testCoreTemplatePlaceholders() {
        let rendered = DailyNoteTemplate.render("{{title}} · {{date}} · {{date:YYYY}}", date: day, title: "Notiz")
        XCTAssertEqual(rendered, "Notiz · 2026-08-13 · 2026")
    }

    /// A confidently wrong value is worse than a visible unrendered tag: the
    /// expressions this can't evaluate must survive untouched.
    func testUnsupportedExpressionsAreLeftStanding() {
        let source = "<%* tp.file.cursor() %>\n<% tp.system.prompt(\"Titel\") %>\n<% tp.frontmatter.foo %>"
        XCTAssertEqual(DailyNoteTemplate.render(source, date: day, title: "x"), source)
    }

    // MARK: moment → DateFormatter

    func testMomentFormatTranslation() {
        XCTAssertEqual(DailyNoteTemplate.dateFormat(fromMoment: "YYYY-MM-DD"), "yyyy-MM-dd")
        XCTAssertEqual(DailyNoteTemplate.dateFormat(fromMoment: "dddd"), "EEEE")
        XCTAssertEqual(DailyNoteTemplate.dateFormat(fromMoment: "HH:mm"), "HH:mm")
        // Bare letters are literals to moment but tokens to DateFormatter, so
        // they have to come back quoted.
        XCTAssertEqual(DailyNoteTemplate.dateFormat(fromMoment: "[KW] ww"), "'KW' ww")
    }

    /// Every token has to be read at its full length: a naive replacement chain
    /// turns `dddd` into `EEdd` by matching `dd` inside it.
    func testLongTokensWinOverTheirPrefixes() {
        XCTAssertEqual(DailyNoteTemplate.dateFormat(fromMoment: "dddd, D. MMMM YYYY"), "EEEE, d. MMMM yyyy")
    }

    // MARK: Finding the template

    func testPrefersTemplaterFolderTemplateOverCoreSetting() throws {
        let root = try makeVault([
            ".obsidian/daily-notes.json": #"{"folder":"01-daily","format":"YYYY-MM-DD","template":"_templates/core"}"#,
            ".obsidian/plugins/templater-obsidian/data.json": #"""
            {"enable_folder_templates":true,
             "folder_templates":[{"folder":"/","template":"_templates/notiz.md"},
                                 {"folder":"01-daily","template":"_templates/daily.md"}]}
            """#,
        ])
        let url = try XCTUnwrap(DailyNoteTemplate.templateURL(root: root, dailyFolder: "01-daily"))
        XCTAssertTrue(url.path.hasSuffix("_templates/daily.md"))
    }

    func testFallsBackToTheCoreDailyNotesTemplate() throws {
        let root = try makeVault([
            ".obsidian/daily-notes.json": #"{"folder":"daily","template":"_templates/daily"}"#,
        ])
        let url = try XCTUnwrap(DailyNoteTemplate.templateURL(root: root, dailyFolder: "daily"))
        XCTAssertTrue(url.path.hasSuffix("_templates/daily.md"), "the extension is Obsidian's to omit")
    }

    func testNoTemplateConfigured() throws {
        let root = try makeVault([".obsidian/daily-notes.json": #"{"folder":"daily","template":""}"#])
        XCTAssertNil(DailyNoteTemplate.templateURL(root: root, dailyFolder: "daily"))
        XCTAssertNil(DailyNoteTemplate.seed(root: root, dailyFolder: "daily", date: day, title: "2026-08-13"))
    }

    /// Folder templates that don't cover the daily folder must not be adopted.
    func testUnrelatedFolderTemplateIsIgnored() throws {
        let root = try makeVault([
            ".obsidian/plugins/templater-obsidian/data.json": #"""
            {"enable_folder_templates":true,
             "folder_templates":[{"folder":"journal","template":"_templates/journal.md"}]}
            """#,
        ])
        XCTAssertNil(DailyNoteTemplate.templateURL(root: root, dailyFolder: "01-daily"))
    }

    func testSeedRendersTheTemplateFile() throws {
        let root = try makeVault([
            ".obsidian/plugins/templater-obsidian/data.json": #"""
            {"enable_folder_templates":true,
             "folder_templates":[{"folder":"01-daily","template":"_templates/daily.md"}]}
            """#,
            "_templates/daily.md": """
            ---
            type: daily
            created: <% tp.date.now("YYYY-MM-DD", 0, tp.file.title, "YYYY-MM-DD") %>
            ---

            ## Capture

            -
            """,
        ])
        let seed = try XCTUnwrap(
            DailyNoteTemplate.seed(root: root, dailyFolder: "01-daily", date: day, title: "2026-08-13"))
        XCTAssertTrue(seed.contains("type: daily"))
        XCTAssertTrue(seed.contains("created: 2026-08-13"))
        XCTAssertFalse(seed.contains("<%"))
    }

    // MARK: Helpers

    private func makeVault(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CoteDOsTemplateVault-\(UUID().uuidString)", isDirectory: true)
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
