import AppKit
import BosunCore
import SwiftUI

/// The sidebar's two lists.
enum SidebarTab: String {
    case sessions, inbox
}

// MARK: Sections

enum InboxSectionID: String, CaseIterable {
    case reviews, assigned, mine, teams, opened, mentions

    var title: String {
        switch self {
        case .reviews: "Review requested"
        case .assigned: "Assigned to you"
        case .mine: "Your pull requests"
        case .teams: "Your teams' review requests"
        case .opened: "Issues you opened"
        case .mentions: "Mentions"
        }
    }

    /// The long ones that rarely need you.
    static let foldedByDefault: Set<InboxSectionID> = [.teams, .opened, .mentions]
}

enum InboxEntry: Identifiable, Equatable {
    case pullRequest(GitHubPullRequest)
    case issue(GitHubIssue)

    /// Unique across both: issues and pull requests share a repository's numbers.
    var id: String {
        switch self {
        case .pullRequest(let pr): pr.id
        case .issue(let issue): issue.id
        }
    }
}

struct InboxListSection: Identifiable, Equatable {
    let id: InboxSectionID
    let entries: [InboxEntry]
    /// What GitHub counted, less the rows an earlier section already has.
    let total: Int
}

extension GitHubInbox {
    /// The Inbox's lists, what needs you first. An issue shows once: one
    /// assigned to you is not listed again as opened by you or mentioning you.
    var listSections: [InboxListSection] {
        var shown = Set<String>()
        func issueSection(_ id: InboxSectionID, _ section: InboxSection<GitHubIssue>) -> InboxListSection {
            let fresh = section.items.filter { shown.insert($0.id).inserted }
            let repeated = section.items.count - fresh.count
            return InboxListSection(id: id, entries: fresh.map(InboxEntry.issue), total: max(section.total - repeated, fresh.count))
        }
        func pullRequestSection(_ id: InboxSectionID, _ section: InboxSection<GitHubPullRequest>) -> InboxListSection {
            InboxListSection(id: id, entries: section.items.map(InboxEntry.pullRequest), total: section.total)
        }
        return [
            pullRequestSection(.reviews, reviewRequests),
            issueSection(.assigned, assignedIssues),
            pullRequestSection(.mine, pullRequests),
            pullRequestSection(.teams, teamReviewRequests),
            issueSection(.opened, openedIssues),
            issueSection(.mentions, mentions),
        ]
    }

    func entry(id: String) -> InboxEntry? {
        listSections.lazy.flatMap(\.entries).first { $0.id == id }
    }
}

// MARK: Looks

extension PullRequestState {
    var symbol: String { self == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull" }

    var color: Color {
        switch self {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

extension IssueState {
    var symbol: String {
        switch self {
        case .open: "smallcircle.filled.circle"
        case .completed: "checkmark.circle"
        case .notPlanned: "slash.circle"
        }
    }

    var color: Color {
        switch self {
        case .open: .green
        case .completed: .purple
        case .notPlanned: .secondary
        }
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .completed: "Closed"
        case .notPlanned: "Not planned"
        }
    }
}

extension CheckState {
    var symbol: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        case .pending: "clock.fill"
        }
    }

    var color: Color {
        switch self {
        case .passing: .green
        case .failing: .red
        case .pending: .yellow
        }
    }

    var label: String {
        switch self {
        case .passing: "Checks pass"
        case .failing: "Checks fail"
        case .pending: "Checks running"
        }
    }
}

extension ReviewDecision {
    var label: String {
        switch self {
        case .required: "Review required"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        }
    }
}

/// `12m`, `3h`, `2d`, `5w`, `3mo`, `9y`: an age that fits a row.
enum ShortAge {
    static func text(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        return switch days {
        case 365...: "\(days / 365)y"
        case 30...: "\(days / 30)mo"
        case 7...: "\(days / 7)w"
        case 1...: "\(days)d"
        default: hours > 0 ? "\(hours)h" : "\(max(minutes, 1))m"
        }
    }
}

enum GitHubLinks {
    /// Only github.com pages: a URL from GitHub's answers, never another scheme.
    static func open(_ url: URL) {
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

// MARK: Chips

/// The pull request from a session's branch, or the bare branch with its
/// unpushed commits; a placeholder of its size while GitHub has yet to
/// say, or while Bosun has yet to read the session's folder (`github` nil).
struct BranchChip: View {
    let github: SessionGitHub?

    var body: some View {
        if let github {
            chip(github)
        } else {
            Self.skeleton
        }
    }

    static var skeleton: some View {
        Text(verbatim: "#000000")
            .monospacedDigit()
            .chip()
            .modifier(LoadingPulse())
            // Redacted text is hidden from VoiceOver; a fresh element says what loads.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading pull request")
    }

    @ViewBuilder private func chip(_ github: SessionGitHub) -> some View {
        if github.pullRequestLoading {
            Self.skeleton
        } else if let pr = github.pullRequest {
            HStack(spacing: 3) {
                Image(systemName: pr.state.symbol).foregroundStyle(pr.state.color)
                Text(verbatim: "#\(pr.number)").monospacedDigit()
                if pr.state == .open || pr.state == .draft {
                    if let checks = pr.checks { Image(systemName: checks.symbol).foregroundStyle(checks.color) }
                    if pr.unresolvedThreads > 0 { Image(systemName: "bubble.left.fill").foregroundStyle(.orange) }
                }
            }
            .chip()
            .help("\(pr.state.label) pull request #\(pr.number): \(pr.title)")
        } else if github.repo?.featureBranch != nil {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                if let unpushed = github.repo?.unpushed, unpushed > 0 {
                    Text(verbatim: "\(unpushed)↑").monospacedDigit()
                }
            }
            .chip()
            .help(branchHelp(github))
        }
    }

    private func branchHelp(_ github: SessionGitHub) -> String {
        let branch = github.repo?.featureBranch ?? ""
        guard let unpushed = github.repo?.unpushed, unpushed > 0 else { return "\(branch), no pull request" }
        return "\(branch), no pull request, \(unpushed) commit\(unpushed == 1 ? "" : "s") not pushed"
    }
}

private extension View {
    func chip() -> some View {
        font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// An issue as a row's subtitle names it: its state, number and title, the
/// title a placeholder while GitHub has yet to describe it.
struct IssueMark: View {
    let issue: LinkedIssue
    var loading = false

    var body: some View {
        HStack(spacing: 3) {
            if let state = issue.issue?.state {
                Image(systemName: state.symbol).foregroundStyle(state.color)
            }
            Text(verbatim: issue.issue.map { "#\($0.number) \($0.title)" } ?? "#\(issue.ref.number)")
            if loading {
                Text(verbatim: "Issue title here")
                    .modifier(LoadingPulse())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading issue")
            }
        }
    }
}

// MARK: List

/// The Inbox tab's list: what asks for you on GitHub, what needs you first.
struct InboxSidebar: View {
    let inbox: InboxCenter
    @Binding var selection: String?
    @SceneStorage("inbox.folded") private var foldedNames = InboxSectionID.foldedByDefault.map(\.rawValue).sorted().joined(separator: " ")

    var body: some View {
        List(selection: $selection) {
            if let fresh = inbox.inbox {
                ForEach(fresh.listSections) { section in
                    Section(isExpanded: expanded(section.id)) {
                        ForEach(section.entries) { entry in
                            InboxRow(entry: entry, linked: linked(entry))
                                .tag(entry.id)
                                .contextMenu { InboxLinkItems(entry: entry) }
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text(section.id.title)
                            Text(verbatim: "\(section.total)").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if inbox.inbox == nil {
                InboxStatusView(inbox: inbox).padding()
            }
        }
    }

    private func expanded(_ id: InboxSectionID) -> Binding<Bool> {
        Binding {
            !foldedNames.split(separator: " ").contains(Substring(id.rawValue))
        } set: { open in
            var names = Set(foldedNames.split(separator: " ").map(String.init))
            if open { names.remove(id.rawValue) } else { names.insert(id.rawValue) }
            foldedNames = names.sorted().joined(separator: " ")
        }
    }

    private func linked(_ entry: InboxEntry) -> Bool {
        switch entry {
        case .pullRequest(let pr): !inbox.sessions(working: pr).isEmpty
        case .issue(let issue): !inbox.sessions(working: issue).isEmpty
        }
    }
}

private struct InboxRow: View {
    let entry: InboxEntry
    let linked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                HStack(spacing: 5) {
                    details
                    Spacer(minLength: 0)
                    Text(ShortAge.text(since: updatedAt)).foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .opacity(linked ? 1 : 0)
                .accessibilityHidden(!linked)
                .help("A session works on this")
        }
        .help(title)
    }

    @ViewBuilder private var details: some View {
        switch entry {
        case .pullRequest(let pr):
            Text(verbatim: "\(pr.repo.name)#\(pr.number)").monospacedDigit()
            if let author = pr.author { Text("· \(author)") }
            if let checks = pr.checks { Image(systemName: checks.symbol).foregroundStyle(checks.color) }
            if pr.review == .changesRequested { Text("· changes requested").foregroundStyle(.red) }
            if pr.review == .approved { Text("· approved").foregroundStyle(.green) }
            if pr.hasConflicts { Text("· conflicts").foregroundStyle(.orange) }
            if pr.unresolvedThreads > 0 {
                Label { Text(verbatim: "\(pr.unresolvedThreads)") } icon: { Image(systemName: "bubble.left.fill") }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
            }
        case .issue(let issue):
            Text(verbatim: "\(issue.repo.name)#\(issue.number)").monospacedDigit()
            ForEach(issue.labels.prefix(2), id: \.self) { Text("· \($0)") }
            if !issue.pullRequests.isEmpty {
                Label { Text(verbatim: "\(issue.pullRequests.count)") } icon: { Image(systemName: "arrow.triangle.pull") }
                    .labelStyle(.titleAndIcon)
            }
            if issue.comments > 0 {
                Label { Text(verbatim: "\(issue.comments)") } icon: { Image(systemName: "bubble.left") }
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var symbol: String {
        switch entry {
        case .pullRequest(let pr): pr.state.symbol
        case .issue(let issue): issue.state.symbol
        }
    }

    private var color: Color {
        switch entry {
        case .pullRequest(let pr): pr.state.color
        case .issue(let issue): issue.state.color
        }
    }

    private var title: String {
        switch entry {
        case .pullRequest(let pr): pr.title
        case .issue(let issue): issue.title
        }
    }

    private var updatedAt: Date {
        switch entry {
        case .pullRequest(let pr): pr.updatedAt
        case .issue(let issue): issue.updatedAt
        }
    }
}

private struct InboxLinkItems: View {
    let entry: InboxEntry

    var body: some View {
        let url = switch entry {
        case .pullRequest(let pr): pr.url
        case .issue(let issue): issue.url
        }
        Button("Open on GitHub") { GitHubLinks.open(url) }
        Button("Copy Link") { GitHubLinks.copy(url) }
    }
}

/// Why the Inbox has nothing to show yet.
private struct InboxStatusView: View {
    let inbox: InboxCenter

    var body: some View {
        switch inbox.status {
        case .idle, .loading:
            ProgressView()
        case .ready:
            ContentUnavailableView("Nothing on GitHub", systemImage: "tray", description: Text("No pull requests or issues ask for you."))
        case .notInstalled:
            ContentUnavailableView("GitHub CLI not found", systemImage: "exclamationmark.triangle",
                                   description: Text("Install it with `brew install gh`, then run `gh auth login`."))
        case .signedOut:
            ContentUnavailableView("Not signed in to GitHub", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Run `gh auth login` in a terminal."))
        case .failed(let message):
            ContentUnavailableView {
                Label("GitHub did not answer", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await inbox.refresh() } }
            }
        }
    }
}

// MARK: Detail

/// The selected pull request or issue, read-only, over the terminals.
struct InboxDetail: View {
    let inbox: InboxCenter
    let entryID: String?
    let showSession: (DeckSession) -> Void

    var body: some View {
        Group {
            if let entry = entryID.flatMap({ inbox.inbox?.entry(id: $0) }) {
                ScrollView {
                    switch entry {
                    case .pullRequest(let pr):
                        PullRequestDetail(pr: pr, sessions: inbox.sessions(working: pr), showSession: showSession)
                    case .issue(let issue):
                        IssueDetail(issue: issue, sessions: inbox.sessions(working: issue), showSession: showSession)
                    }
                }
            } else if inbox.inbox == nil {
                InboxStatusView(inbox: inbox)
            } else {
                ContentUnavailableView("Select a pull request or issue", systemImage: "tray.full",
                                       description: Text(updatedText))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var updatedText: String {
        if case .failed(let message) = inbox.status { return "Last update failed: \(message)" }
        return inbox.updatedAt.map { "Updated \(ShortAge.text(since: $0)) ago; again every 5 minutes." } ?? ""
    }
}

private struct PullRequestDetail: View {
    let pr: GitHubPullRequest
    let sessions: [DeckSession]
    let showSession: (DeckSession) -> Void

    var body: some View {
        DetailLayout(
            state: (pr.state.label, pr.state.symbol, pr.state.color),
            reference: "\(pr.repo) #\(pr.number)", title: pr.title,
            byline: "\(pr.headBranch) → \(pr.baseBranch) · \(pr.author.map { "by \($0)" } ?? "author unknown") · updated \(ShortAge.text(since: pr.updatedAt)) ago",
            url: pr.url, sessions: sessions, showSession: showSession
        ) {
            HStack(spacing: 8) {
                if let checks = pr.checks {
                    Tile(title: "Checks", value: checks.label, symbol: checks.symbol, color: checks.color)
                }
                Tile(title: "Review", value: pr.review?.label ?? "None yet", symbol: "person.2",
                     color: pr.review == .changesRequested ? .red : pr.review == .approved ? .green : .primary)
                Tile(title: "Threads", value: pr.unresolvedThreads > 0 ? "\(pr.unresolvedThreads) unresolved" : "All resolved",
                     symbol: "bubble.left.fill", color: pr.unresolvedThreads > 0 ? .orange : .secondary)
                Tile(title: "Merge", value: pr.hasConflicts ? "Conflicts" : "No conflicts",
                     symbol: pr.hasConflicts ? "exclamationmark.triangle.fill" : "checkmark.circle",
                     color: pr.hasConflicts ? .orange : .secondary)
            }
            if !pr.closingIssues.isEmpty {
                DetailSection(title: "Fixes") {
                    ForEach(pr.closingIssues) { InboxRow(entry: .issue($0), linked: false) }
                }
            }
        }
    }
}

private struct IssueDetail: View {
    let issue: GitHubIssue
    let sessions: [DeckSession]
    let showSession: (DeckSession) -> Void

    var body: some View {
        DetailLayout(
            state: (issue.state.label, issue.state.symbol, issue.state.color),
            reference: "\(issue.repo) #\(issue.number)", title: issue.title,
            byline: "\(issue.author.map { "Opened by \($0)" } ?? "Author unknown") · updated \(ShortAge.text(since: issue.updatedAt)) ago",
            url: issue.url, sessions: sessions, showSession: showSession
        ) {
            HStack(spacing: 8) {
                Tile(title: "Assignees", value: issue.assignees.isEmpty ? "Nobody" : issue.assignees.joined(separator: ", "), symbol: "person")
                Tile(title: "Labels", value: issue.labels.isEmpty ? "None" : issue.labels.joined(separator: ", "), symbol: "tag")
                Tile(title: "Comments", value: "\(issue.comments)", symbol: "bubble.left", color: .secondary)
            }
            if !issue.pullRequests.isEmpty {
                DetailSection(title: "Pull requests") {
                    ForEach(issue.pullRequests) { InboxRow(entry: .pullRequest($0), linked: false) }
                }
            }
        }
    }
}

/// What every detail has: its state and title, the sessions on it, and the
/// way to GitHub; `content` goes in between.
private struct DetailLayout<Content: View>: View {
    let state: (label: String, symbol: String, color: Color)
    let reference: String
    let title: String
    let byline: String
    let url: URL
    let sessions: [DeckSession]
    let showSession: (DeckSession) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(state.label, systemImage: state.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(state.color.opacity(0.2), in: .capsule)
                        .foregroundStyle(state.color)
                    Text(verbatim: reference).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(byline).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            content
            if !sessions.isEmpty {
                DetailSection(title: sessions.count == 1 ? "Session" : "Sessions") {
                    ForEach(sessions) { session in
                        HStack(spacing: 8) {
                            Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 14)
                            Text(session.title)
                            Text("· \(session.status.label)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Show Session") { showSession(session) }
                        }
                        .padding(6)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Open on GitHub", systemImage: "safari") { GitHubLinks.open(url) }
                Button("Copy Link", systemImage: "link") { GitHubLinks.copy(url) }
            }
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let symbol: String
    var color = Color.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Label(value, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .help(value)
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}
