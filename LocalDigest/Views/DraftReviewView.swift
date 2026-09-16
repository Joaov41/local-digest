import SwiftUI

struct DraftReviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let draft: ReplyDraft

    @State private var recipient: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var isConfirmingSend = false
    @State private var isSending = false

    init(draft: ReplyDraft) {
        self.draft = draft
        _recipient = State(initialValue: draft.recipient)
        _subject = State(initialValue: draft.subject)
        _bodyText = State(initialValue: draft.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Label("Review reply", systemImage: "paperplane.fill")
                    .font(.headline)
                Text(draft.channel.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Spacer()
                if store.isDrafting { ProgressView().controlSize(.small) }
            }

            Text("Nothing is sent until you approve it below. Edit anything before sending.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(draft.channel == .mail ? "To" : "Chat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    TextField(draft.channel == .mail ? "name@example.com" : "iMessage;+15551234567", text: $recipient)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }
                if draft.channel == .mail {
                    HStack(spacing: 8) {
                        Text("Subject")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        TextField("Subject", text: $subject)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                TextEditor(text: $bodyText)
                    .font(.body)
                    .frame(minHeight: 180, maxHeight: 320)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
            }

            if !draft.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grounded in")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(draft.evidence.prefix(4)) { citation in
                        CitationRow(citation: citation)
                    }
                }
            }

            if let error = store.draftErrorMessage {
                ErrorBanner(message: error)
            }

            HStack {
                Text("Sending uses Mail or Messages automation on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Discard") { store.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sendableBody, forType: .string)
                }
                Button {
                    isConfirmingSend = true
                } label: {
                    Label(isSending ? "Sending" : "Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSend || isSending)
            }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog(
            confirmTitle,
            isPresented: $isConfirmingSend,
            titleVisibility: .visible
        ) {
            Button("Send now") { Task { await send() } }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("The reply will be sent through \(draft.channel.title). This cannot be undone.")
        }
    }

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespaces).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendableBody: String {
        draft.channel == .mail && !subject.isEmpty ? "Subject: \(subject)\n\n\(bodyText)" : bodyText
    }

    private var confirmTitle: String {
        "Send via \(draft.channel.title) to \(recipient)?"
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        var updated = draft
        updated.recipient = recipient.trimmingCharacters(in: .whitespaces)
        updated.subject = subject
        updated.body = bodyText
        await store.confirmSend(draft: updated)
        if store.draftErrorMessage == nil {
            dismiss()
        }
    }
}
