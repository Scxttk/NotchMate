import Foundation

/// The vault's daily-note template, found and rendered without Obsidian.
///
/// Capture and the focus-timer log write into today's daily note, and until now
/// they created it as a bare file when it didn't exist yet: heading, bullet,
/// nothing else. In a vault where the daily template carries the frontmatter the
/// Bases dashboards filter on (`type`, habit booleans, …) that is worse than no
/// note at all — the day silently drops out of every view, and the real note can
/// no longer be created because the file is already there.
///
/// Templater only runs inside Obsidian, so its expressions are rendered here for
/// the subset a daily template actually uses: `tp.date.*` and `tp.file.title`,
/// plus the core Templates plugin's `{{date}}`/`{{time}}`/`{{title}}`. Anything
/// else is left standing verbatim — a visible unrendered tag is a much smaller
/// problem than a confidently wrong value, and it tells the user which line to
/// look at.
enum DailyNoteTemplate {

    /// Content for a daily note that doesn't exist yet, or nil when the vault
    /// has no template configured for the daily folder.
    static func seed(root: URL, dailyFolder: String, date: Date, title: String) -> String? {
        guard let url = templateURL(root: root, dailyFolder: dailyFolder),
              CaptureEscaping.isInside(url, root: root),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return render(raw, date: date, title: title)
    }

    // MARK: - Finding the template

    /// Where the vault says a new note in `dailyFolder` gets its content from.
    ///
    /// Templater's folder templates first, because a vault that has them is
    /// driven by them (the core daily-notes template field is usually left empty
    /// there, as it is in this one); the core "Daily notes" template second.
    static func templateURL(root: URL, dailyFolder: String) -> URL? {
        if let path = templaterFolderTemplate(root: root, dailyFolder: dailyFolder) {
            return markdownURL(path, root: root)
        }
        if let path = coreDailyTemplate(root: root) {
            return markdownURL(path, root: root)
        }
        return nil
    }

    /// The deepest `folder_templates` entry containing the daily folder — the
    /// same "most specific folder wins" rule Templater applies.
    private static func templaterFolderTemplate(root: URL, dailyFolder: String) -> String? {
        let config = root.appendingPathComponent(".obsidian/plugins/templater-obsidian/data.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["enable_folder_templates"] as? Bool ?? false,
              let entries = json["folder_templates"] as? [[String: Any]]
        else { return nil }

        let folder = normalizedFolder(dailyFolder)
        var best: (depth: Int, template: String)?
        for entry in entries {
            guard let candidate = entry["folder"] as? String,
                  let template = entry["template"] as? String, !template.isEmpty
            else { continue }
            let scope = normalizedFolder(candidate)
            guard scope.isEmpty || folder == scope || folder.hasPrefix(scope + "/") else { continue }
            let depth = scope.isEmpty ? 0 : scope.components(separatedBy: "/").count
            if best == nil || depth > best!.depth { best = (depth, template) }
        }
        return best?.template
    }

    /// The core "Daily notes" plugin's template path (empty when unset).
    private static func coreDailyTemplate(root: URL) -> String? {
        let config = root.appendingPathComponent(".obsidian/daily-notes.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = json["template"] as? String,
              !template.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return template
    }

    /// Obsidian stores template paths vault-relative and usually without the
    /// extension.
    private static func markdownURL(_ path: String, root: URL) -> URL {
        var relative = path.trimmingCharacters(in: .whitespaces)
        while relative.hasPrefix("/") { relative.removeFirst() }
        if !relative.lowercased().hasSuffix(".md") { relative += ".md" }
        return root.appendingPathComponent(relative)
    }

    private static func normalizedFolder(_ folder: String) -> String {
        var value = folder.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value == "." ? "" : value
    }

    // MARK: - Rendering

    /// Fill in the template's date/title expressions for `date`. `title` is the
    /// note's filename without extension — what `tp.file.title` resolves to, and
    /// what a daily template dates itself from.
    static func render(_ template: String, date: Date, title: String) -> String {
        var output = replacingMatches(of: "<%[-_]?(.*?)[-_]?%>", in: template) { expression in
            templaterValue(expression, date: date, title: title)
        }
        output = replacingMatches(of: "\\{\\{(.*?)\\}\\}", in: output) { expression in
            coreTemplateValue(expression, date: date, title: title)
        }
        return output
    }

    /// Value of one `<% … %>` expression, or nil to leave the tag untouched.
    private static func templaterValue(_ expression: String, date: Date, title: String) -> String? {
        let source = expression.trimmingCharacters(in: .whitespaces)
        if source == "tp.file.title" { return title }

        guard let call = functionCall(in: source) else { return nil }
        let arguments = call.arguments
        switch call.name {
        case "tp.date.now", "tp.file.creation_date", "tp.file.last_modified_date":
            // now(format, offset, reference, referenceFormat): the offset counts
            // days off `reference`, which in a daily template is the note's own
            // title — i.e. the day the note is for, not the day it is written.
            let offset = arguments.count > 1 ? Int(arguments[1]) ?? 0 : 0
            return formatted(date, offsetDays: offset, moment: arguments.first)
        case "tp.date.tomorrow":
            return formatted(date, offsetDays: 1, moment: arguments.first)
        case "tp.date.yesterday":
            return formatted(date, offsetDays: -1, moment: arguments.first)
        default:
            return nil
        }
    }

    /// Value of one `{{ … }}` expression from the core Templates plugin.
    private static func coreTemplateValue(_ expression: String, date: Date, title: String) -> String? {
        let parts = expression.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let format = parts.count > 1 ? String(parts[1]) : nil
        switch name {
        case "title": return title
        case "date": return formatted(date, offsetDays: 0, moment: format ?? "YYYY-MM-DD")
        case "time": return formatted(date, offsetDays: 0, moment: format ?? "HH:mm")
        default: return nil
        }
    }

    private static func formatted(_ date: Date, offsetDays: Int, moment: String?) -> String {
        let day = Calendar.current.date(byAdding: .day, value: offsetDays, to: date) ?? date
        let formatter = DateFormatter()
        // Weekday and month names come out in the vault's language, which is the
        // one the Mac is set to — Obsidian's moment locale follows its own UI
        // language, and this is as close as the app can get without reading it.
        formatter.locale = Locale.current
        formatter.dateFormat = dateFormat(fromMoment: moment ?? "YYYY-MM-DD")
        return formatter.string(from: day)
    }

    // MARK: - moment.js → DateFormatter

    /// The moment tokens a note template realistically uses, longest first so
    /// the scanner can't match `MM` inside `MMMM`.
    private static let momentTokens: [(String, String)] = [
        ("YYYY", "yyyy"), ("YY", "yy"),
        ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
        ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"),
        ("dddd", "EEEE"), ("ddd", "EEE"), ("dd", "EEEEEE"), ("d", "e"),
        ("ww", "ww"), ("w", "w"), ("gggg", "YYYY"),
        ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"),
        ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"),
        ("SSS", "SSS"), ("A", "a"), ("a", "a"), ("ZZ", "ZZ"), ("Z", "ZZZZZ"),
    ]

    /// Translate a moment pattern into `DateFormatter` syntax.
    ///
    /// A scanner rather than a chain of `replacingOccurrences`: substitutions
    /// feed on each other's output (`dddd` → `EEEE`, then a later `DD` rule
    /// mangling what the first one wrote), and every letter that isn't a known
    /// token has to be quoted or `DateFormatter` reads it as a token of its own.
    static func dateFormat(fromMoment pattern: String) -> String {
        var result = ""
        var literal = ""
        var index = pattern.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            result += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }

        outer: while index < pattern.endIndex {
            // moment escapes literal text in square brackets.
            if pattern[index] == "[" {
                if let end = pattern[index...].firstIndex(of: "]") {
                    literal += pattern[pattern.index(after: index)..<end]
                    index = pattern.index(after: end)
                    continue
                }
            }
            for (moment, unicode) in momentTokens where pattern[index...].hasPrefix(moment) {
                flushLiteral()
                result += unicode
                index = pattern.index(index, offsetBy: moment.count)
                continue outer
            }
            let character = pattern[index]
            if character.isLetter || character == "'" {
                literal.append(character)
            } else {
                flushLiteral()
                result.append(character)
            }
            index = pattern.index(after: index)
        }
        flushLiteral()
        return result
    }

    // MARK: - Helpers

    /// Split `name(arg, arg)` into its parts, unquoting string arguments.
    /// Returns nil for anything that isn't a plain call — a JS block, an
    /// expression with operators, a variable — which is exactly what should be
    /// left unrendered.
    private static func functionCall(in source: String) -> (name: String, arguments: [String])? {
        guard let open = source.firstIndex(of: "("), source.hasSuffix(")") else { return nil }
        let name = String(source[source.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "." || $0 == "_" }) else { return nil }
        let inner = source[source.index(after: open)..<source.index(before: source.endIndex)]
        guard !inner.contains("(") else { return nil }  // nested call — not our business
        let arguments = inner
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        return (name, inner.isEmpty ? [] : arguments)
    }

    /// Replace every regex match by the transform's value, keeping the original
    /// text wherever it returns nil.
    private static func replacingMatches(
        of pattern: String, in text: String, transform: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let full = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: full) {
            guard let whole = Range(match.range, in: text),
                  let captured = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            result += transform(String(text[captured])) ?? String(text[whole])
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}
