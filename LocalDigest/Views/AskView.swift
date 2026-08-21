import SwiftUI

struct AskView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask across your life")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .tracking(-0.7)
                    Text("Search Mail, Messages, Notes, Calendar, Reminders, and Contacts together. Every answer stays grounded in the sources you can inspect.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 650, alignment: .leading)
                }

                GlassEffectContainer(spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Ask Local Digest", systemImage: "sparkles")
                                .font(.headline)
                            Spacer()
                            ProviderBadge(provider: store.provider)
                            Button { Task { await store.startNewConversation() } } label: {
                                Label("New conversation", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("New conversation")
                            .help("Start a new conversation (Command-N)")
                            .disabled(store.isAnswering)
                        }
                        TextField("What did Rui tell me last night? Summarize our conversation.", text: $store.question, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .lineLimit(3...6)
                            .onSubmit { Task { await store.ask() } }
                        HStack {
                            Text("Only retrieved evidence is sent to the selected Apple model.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { Task { await store.ask() } } label: {
                                Label(store.isAnswering ? "Working" : "Ask", systemImage: store.isAnswering ? "ellipsis" : "arrow.up")
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(store.isAnswering || store.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }

                if let error = store.errorMessage { ErrorBanner(message: error) }
                if !conversationHistory.isEmpty {
                    ConversationHistoryView(turns: conversationHistory)
                }
                if store.isAnswering && store.answerText.isEmpty { AnswerSkeleton() }
                if !store.answerText.isEmpty { AnswerResult() }
                if store.answerText.isEmpty && !store.isAnswering { AskEmptyState() }
            }
            .padding(38)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .inspector(isPresented: Binding(
            get: { store.selectedHit != nil },
            set: { if !$0 { store.selectedHit = nil } }
        )) {
            EvidenceInspector(hit: store.selectedHit)
        }
    }

    private var conversationHistory: [ConversationTurn] {
        guard !store.isAnswering, !store.answerText.isEmpty, !store.conversationTurns.isEmpty else {
            return store.conversationTurns
        }
        return Array(store.conversationTurns.dropLast())
    }
}

struct ConversationHistoryView: View {
    let turns: [ConversationTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Conversation", systemImage: "text.bubble")
                .font(.headline)
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: 8) {
                    Text(turn.question)
                        .font(.subheadline.weight(.semibold))
                    Text(turn.answer)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(turn.provider.title)
                        if !turn.citations.isEmpty { Text("· \(turn.citations.count) sources") }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct ProviderBadge: View {
    let provider: AIProvider
    var body: some View {
        Label(provider.title, systemImage: provider.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

struct AnswerResult: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Answer", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                        Text(store.provider.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { store.saveCurrentAnswer() } label: {
                    Label("Save", systemImage: "bookmark")
                }
                .buttonStyle(.borderless)
            }
            Text(store.answerText)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: 700, alignment: .leading)
            if !store.hits.isEmpty {
                Divider()
                Text("Sources")
                    .font(.headline)
                ForEach(store.hits.prefix(8)) { hit in
                    Button { store.selectedHit = hit } label: {
                        CitationRow(citation: hit.citation)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct EvidenceInspector: View {
    let hit: SearchHit?

    var body: some View {
        Group {
            if let hit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(hit.record.source.title, systemImage: hit.record.source.symbol)
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                        Text(hit.record.title)
                            .font(.title3.weight(.semibold))
                        if let author = hit.record.author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if hit.record.timestamp.isUsableSourceDate {
                            Text(hit.record.timestamp.formatted(date: .complete, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        if let matchedSnippet = hit.matchedSnippet {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Matching text")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(matchedSnippet)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        Text(hit.record.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Retrieved evidence is shown read-only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("Select a source", systemImage: "doc.text.magnifyingglass")
            }
        }
        .frame(minWidth: 280)
    }
}

struct CitationRow: View {
    let citation: Citation
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: citation.source.symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 19)
            VStack(alignment: .leading, spacing: 3) {
                Text(citation.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(citation.timestamp.isUsableSourceDate
                    ? "\(citation.source.title) · \(citation.timestamp.formatted(date: .abbreviated, time: .shortened))"
                    : citation.source.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if citation.url != nil { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}

struct AnswerSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.13)).frame(width: 180, height: 14)
            RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 14)
            RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.10)).frame(width: 470, height: 14)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .redacted(reason: .placeholder)
    }
}

struct AskEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your answer will appear here", systemImage: "quote.opening")
                .font(.headline)
            Text("Try a person, a date, or a source. Local Digest searches your indexed history instead of only looking at the latest item.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}
