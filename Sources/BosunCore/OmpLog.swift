@preconcurrency import Foundation

/// omp's session logs (`~/.omp/agent/sessions/<folder>/<start>_<id>.jsonl`),
/// one JSON object per line. The first user message is what the session
/// was asked to do.
public enum OmpLog {
    /// omp's folder for runs in `path`: the path from home, `/` as `-`,
    /// behind a `-`, as `-dev-agent-deck` for `~/dev/agent-deck`.
    public static func directory(forWorkingDirectory path: String, home: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let relative = resolved.hasPrefix(homePath + "/") ? String(resolved.dropFirst(homePath.count + 1)) : String(resolved.drop { $0 == "/" })
        return "\(home)/.omp/agent/sessions/-" + relative.replacingOccurrences(of: "/", with: "-")
    }

    /// The issue in the first prompt of omp's newest run in `path`, the run
    /// a session's pane most likely shows. Reads the log's first MiB only:
    /// the first user message comes right after its header.
    public static func firstIssue(
        forWorkingDirectory path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> IssueRef? {
        let directory = directory(forWorkingDirectory: path, home: home)
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        let newest = names.lazy.filter { $0.hasSuffix(".jsonl") }.map { "\(directory)/\($0)" }
            .compactMap { path in
                (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date).map { (path, $0) }
            }
            .max { $0.1 < $1.1 }
        guard let newest, let handle = FileHandle(forReadingAtPath: newest.0) else { return nil }
        defer { try? handle.close() }
        return firstIssue(inLog: (try? handle.read(upToCount: 1 << 20)) ?? Data())
    }

    /// The issue URL in the first user message of a log's opening `data`;
    /// nil when that message names none. Later messages are not the
    /// session's purpose and are not read.
    public static func firstIssue(inLog data: Data) -> IssueRef? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                  entry.type == "message", entry.message?.role == "user"
            else { continue }
            return entry.message?.content.flatMap { IssueRef.firstURL(in: $0.text) }
        }
        return nil
    }

    private struct Entry: Decodable {
        let type: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let role: String?
        let content: Content?
    }

    /// A message's text: a string, or parts of which the text ones count.
    private enum Content: Decodable {
        case text(String)
        case parts([Part])

        struct Part: Decodable {
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .parts(try container.decode([Lossy<Part>].self).compactMap(\.value))
            }
        }

        var text: String {
            switch self {
            case .text(let text): text
            case .parts(let parts): parts.compactMap(\.text).joined(separator: "\n")
            }
        }
    }
}
