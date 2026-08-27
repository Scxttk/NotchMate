import AppKit

/// Reads/writes an Obsidian vault directly on the filesystem. The vault is just
/// a folder of `.md` files, so capture appends to today's daily note under a
/// configured heading — silent, no plugin, works even when Obsidian is closed.
struct ObsidianVault {

    enum CaptureError: Error {
        case noVault            // no vault folder configured / bookmark unresolvable
        case outsideVault       // computed note path escaped the vault root
        case writeFailed(Error)
        case noBrowserPage      // no frontmost Safari/Chrome tab available
    }

    /// Append a plain capture line. `asLink == false` adds a `- ` bullet around
    /// `text`; for pre-formatted markdown (e.g. a `[title](url)` link) pass the
    /// content and `asLink == true` to skip the timestamp/escaping of the body.
    func append(text: String, asLink: Bool, settings: UserSettings) throws -> URL {
        let day = Date()
        let (noteURL, root, dateString) = try resolveDailyNote(on: day, settings: settings)

        let bullet = formatBullet(text, asLink: asLink, settings: settings)
        try insert(bullet: bullet, underHeading: settings.captureHeading, into: noteURL,
                   seed: Self.seed(root: root, day: day, title: dateString, settings: settings))

        if settings.captureMode == .openInObsidian {
            openInObsidian(folder: settings.dailyFolder, file: dateString, root: root, settings: settings)
        }
        return noteURL
    }

    /// Log a focus-preset timer session as a Dataview-friendly bullet under
    /// `settings.focusHeading`, so daily concentrated-work time can be summed
    /// with a `[minutes::]` query. `start` + `minutes` describe the run;
    /// `minutes` is the actually elapsed time, not necessarily the preset's
    /// full duration (an aborted session is logged with what really happened).
    ///
    /// Filed under the day the session *started*, not the day it ended: a block
    /// running through midnight belongs to the evening it was worked, which is
    /// also the only reading under which the bullet's own `23:50–00:15` makes
    /// sense in the note it sits in.
    @discardableResult
    func appendFocusSession(name: String, start: Date, minutes: Int, settings: UserSettings) throws -> URL {
        let (noteURL, root, dateString) = try resolveDailyNote(on: start, settings: settings)
        let end = start.addingTimeInterval(TimeInterval(minutes) * 60)
        let bullet = "- \(Self.timeFormatter.string(from: start))–\(Self.timeFormatter.string(from: end)) "
            + "\(CaptureEscaping.sanitizeLine(name)) (\(minutes) min) "
            + "[start:: \(Self.isoFormatter.string(from: start))] [minutes:: \(minutes)]"
        try insert(bullet: bullet, underHeading: settings.focusHeading, into: noteURL,
                   seed: Self.seed(root: root, day: start, title: dateString, settings: settings))
        return noteURL
    }

    /// The content a daily note that doesn't exist yet is created with: the
    /// vault's own daily template, rendered for that day (see
    /// `DailyNoteTemplate`). Empty when the vault has no template — then the
    /// note is built out of the heading and the bullet alone, as it always was.
    private static func seed(root: URL, day: Date, title: String, settings: UserSettings) -> () -> String {
        { DailyNoteTemplate.seed(root: root, dailyFolder: settings.dailyFolder, date: day, title: title) ?? "" }
    }

    /// Resolve the vault root and the path of `day`'s daily note, checking the
    /// note doesn't escape the vault. Shared by every writer in this type; the
    /// returned name is also the note's title for template rendering.
    private func resolveDailyNote(on day: Date, settings: UserSettings) throws
        -> (note: URL, root: URL, name: String) {
        guard let bookmark = settings.vaultBookmark,
              let root = Persistence.resolveBookmark(bookmark) else {
            throw CaptureError.noVault
        }

        let dateString = dailyFormatter(settings.dailyFormat).string(from: day)
        let noteURL = root
            .appendingPathComponent(settings.dailyFolder, isDirectory: true)
            .appendingPathComponent(dateString + ".md")

        guard CaptureEscaping.isInside(noteURL, root: root) else {
            throw CaptureError.outsideVault
        }
        return (noteURL, root, dateString)
    }

    /// Insert `bullet` under `heading` in the note at `noteURL`, creating
    /// intermediate folders as needed. A note that isn't there yet is built from
    /// `seed` first — writing the day's first capture must not cost the user the
    /// daily template, since a file that exists is a file Obsidian will never
    /// template again.
    private func insert(bullet: String, underHeading heading: String, into noteURL: URL,
                        seed: () -> String) throws {
        let stored = try? String(contentsOf: noteURL, encoding: .utf8)
        let isBlank = stored?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let existing = isBlank ? seed() : (stored ?? "")
        let updated = Self.appending(bullet: bullet, underHeading: heading, to: existing)
        do {
            try FileManager.default.createDirectory(
                at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: noteURL, options: .atomic)
        } catch {
            throw CaptureError.writeFailed(error)
        }
    }

    /// Capture the frontmost browser tab as a markdown link.
    @discardableResult
    func appendCurrentBrowserPage(settings: UserSettings) throws -> URL {
        guard let page = Self.frontmostBrowserPage() else { throw CaptureError.noBrowserPage }
        let title = CaptureEscaping.sanitizeLinkTitle(page.title)
        let destination = CaptureEscaping.sanitizeLinkDestination(page.url)
        return try append(text: "[\(title)](\(destination))", asLink: true, settings: settings)
    }

    // MARK: - Pure insertion logic (unit-tested)

    /// Insert `bullet` under the markdown heading matching `heading`, at the end
    /// of that heading's section (just before the next heading or EOF). Creates
    /// the heading at the end of the document if it's missing, and replaces a
    /// lone empty `- ` placeholder bullet (as produced by the daily-note
    /// template).
    static func appending(bullet: String, underHeading heading: String, to content: String) -> String {
        let target = heading.trimmingCharacters(in: .whitespaces)
        var lines = content.components(separatedBy: "\n")

        guard let headingIdx = index(ofHeading: target, in: lines) else {
            var result = content
            if !result.isEmpty {
                result += result.hasSuffix("\n") ? "\n" : "\n\n"
            }
            result += "\(heading)\n\n\(bullet)\n"
            return result
        }

        // End of section = next heading line after the target, else EOF.
        var sectionEnd = lines.count
        if headingIdx + 1 < lines.count {
            for i in (headingIdx + 1)..<lines.count where lines[i].hasPrefix("#") {
                sectionEnd = i
                break
            }
        }

        // Insert after the last non-empty line in the section.
        var lastNonEmpty = headingIdx
        if headingIdx + 1 < sectionEnd {
            for i in (headingIdx + 1)..<sectionEnd
            where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                lastNonEmpty = i
            }
        }

        if lastNonEmpty != headingIdx,
           lines[lastNonEmpty].trimmingCharacters(in: .whitespaces) == "-" {
            // Reuse the template's empty placeholder bullet.
            lines[lastNonEmpty] = bullet
        } else {
            lines.insert(bullet, at: lastNonEmpty + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Where the configured heading actually is. Exact text first, so a note
    /// that spells it the same way is matched the same way it always was; a
    /// decorated version of the same heading second.
    ///
    /// Headings get dressed up. Obsidian's Iconize plugin writes `## :LiInbox:
    /// Capture`, people put an emoji in front, and either way the settings field
    /// still says `## 📥 Capture` — no match, and captures land in a second
    /// section the app quietly appends to the bottom of the note. That failure
    /// is invisible until you go looking for something you filed, so the
    /// comparison ignores the decoration and reads the words.
    private static func index(ofHeading target: String, in lines: [String]) -> Int? {
        if let exact = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == target
        }) {
            return exact
        }
        let wanted = headingWords(target)
        guard !wanted.isEmpty else { return nil }
        return lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && headingWords($0) == wanted
        }
    }

    /// A heading reduced to the words it is named after: no `#` markers, no
    /// `:icon:` tokens, no emoji or punctuation, case-folded.
    ///
    /// The `:token:` pass has to run before the punctuation one, or Iconize's
    /// icon name survives as letters and `:LiInbox: Capture` reads as
    /// "liinbox capture".
    static func headingWords(_ line: String) -> String {
        var text = line.drop(while: { $0 == "#" }).replacingOccurrences(
            of: ":[A-Za-z0-9_-]+:", with: " ", options: .regularExpression)
        text = String(text.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        })
        return text.split(separator: " ").joined(separator: " ").lowercased()
    }

    // MARK: - Helpers

    private func formatBullet(_ text: String, asLink: Bool, settings: UserSettings) -> String {
        let body = asLink ? text : CaptureEscaping.sanitizeLine(text)
        guard settings.captureTimestamp else { return "- \(body)" }
        let time = Self.timeFormatter.string(from: Date())
        return "- \(time) \(body)"
    }

    private func dailyFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = CaptureEscaping.normalizedDateFormat(pattern)
        return formatter
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Dataview-parseable local timestamp for the `[start::]` inline field.
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    private func openInObsidian(folder: String, file: String, root: URL, settings: UserSettings) {
        let vault = settings.vaultName.isEmpty ? root.lastPathComponent : settings.vaultName
        let path = folder.isEmpty ? file : "\(folder)/\(file)"
        let urlString = "obsidian://open?vault=\(CaptureEscaping.urlEncoded(vault))&file=\(CaptureEscaping.urlEncoded(path))"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Browser scripting

    private static func frontmostBrowserPage() -> (title: String, url: String)? {
        // Prefer whichever browser is frontmost; otherwise try Safari then Chrome.
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let order: [Browser]
        switch bundle {
        case "com.apple.Safari": order = [.safari, .chrome]
        case "com.google.Chrome": order = [.chrome, .safari]
        default: order = [.safari, .chrome]
        }
        for browser in order {
            if let page = browser.currentPage() { return page }
        }
        return nil
    }

    private enum Browser {
        case safari, chrome

        var appName: String { self == .safari ? "Safari" : "Google Chrome" }

        var script: String {
            switch self {
            case .safari:
                return """
                if application "Safari" is running then
                    tell application "Safari"
                        if (count of windows) is 0 then return ""
                        set theURL to URL of current tab of front window
                        set theTitle to name of current tab of front window
                        return theTitle & "|||" & theURL
                    end tell
                else
                    return ""
                end if
                """
            case .chrome:
                return """
                if application "Google Chrome" is running then
                    tell application "Google Chrome"
                        if (count of windows) is 0 then return ""
                        set theURL to URL of active tab of front window
                        set theTitle to title of active tab of front window
                        return theTitle & "|||" & theURL
                    end tell
                else
                    return ""
                end if
                """
            }
        }

        func currentPage() -> (title: String, url: String)? {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: script) else { return nil }
            let output = script.executeAndReturnError(&error).stringValue ?? ""
            if let error {
                NSLog("CoteDOs: \(appName) browser-capture error: \(error)")
                return nil
            }
            let parts = output.components(separatedBy: "|||")
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }
}
