import Foundation

/// A markdown to-do list, line by line: the headings that section it, the
/// `- [ ]` items under them, and every other line as it was. The text is
/// the list; a change is a new text, so what an agent wrote by hand and
/// what a click ticked read the same way.
public struct TodoDocument: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        case heading(level: Int, title: String)
        /// `indent` is the leading whitespace, which nests an item under the one above.
        case item(done: Bool, text: String, indent: Int)
        case other(String)
    }

    public let text: String
    public let lines: [Line]
    private let raw: [Substring]

    public init(text: String) {
        self.text = text
        raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines = raw.map(Self.parse)
    }

    /// Nothing but whitespace.
    public var isEmpty: Bool {
        text.allSatisfy(\.isWhitespace)
    }

    /// Items not ticked, under a heading or not.
    public var openCount: Int {
        lines.reduce(0) { count, line in
            if case .item(done: false, _, _) = line { count + 1 } else { count }
        }
    }

    /// The text with the item on line `index` ticked if it was open, open
    /// if it was ticked; nil for a line that is no item. Only the mark
    /// changes: the bullet, its spacing and the text stay as written.
    public func toggling(lineAt index: Int) -> String? {
        guard raw.indices.contains(index), let match = raw[index].wholeMatch(of: Self.item) else { return nil }
        var line = raw[index]
        let mark = match.output.mark
        line.replaceSubrange(mark.startIndex..<mark.endIndex, with: mark == " " ? "x" : " ")
        var lines = raw
        lines[index] = line
        return lines.joined(separator: "\n")
    }

    /// Literals built per use: a Regex is not Sendable, so none can be stored.
    private static var heading: Regex<(Substring, marks: Substring, title: Substring)> {
        /^(?<marks>#{1,6})[ \t]+(?<title>.*?)[ \t]*$/
    }

    /// GitHub's task list item: a bullet, then `[ ]` or `[x]`, then the text.
    private static var item: Regex<(Substring, indent: Substring, mark: Substring, text: Substring?)> {
        /^(?<indent>[ \t]*)[-*+][ \t]+\[(?<mark>[ xX])\](?:[ \t]+(?<text>.*?))?[ \t]*$/
    }

    private static func parse(_ line: Substring) -> Line {
        if let match = line.wholeMatch(of: heading) {
            return .heading(level: match.output.marks.count, title: String(match.output.title))
        }
        if let match = line.wholeMatch(of: item) {
            return .item(done: match.output.mark != " ", text: match.output.text.map(String.init) ?? "", indent: match.output.indent.count)
        }
        return .other(String(line))
    }
}
