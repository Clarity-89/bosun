import SwiftUI

/// Grey rows in the session list's shape while the first `list` runs, so
/// the sessions replace something instead of appearing from nothing.
struct SessionListPlaceholder: View {
    /// Made-up groups and titles: redacted, only their lengths show.
    private static let groups: [(name: String, titles: [String])] = [
        ("Group name", ["Session title here", "A longer session title here", "Short title"]),
        ("Another group", ["Session title", "A rather long session title"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.groups, id: \.name) { group in
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(group.titles, id: \.self) { title in
                    HStack(spacing: 8) {
                        Circle().frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                            Text("tool · status").font(.caption)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .modifier(LoadingPulse())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading sessions")
    }
}

/// What is still loading: redacted to its shape, pulsing unless motion is
/// reduced.
struct LoadingPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .opacity(dimmed ? 0.4 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dimmed = true }
            }
    }
}
