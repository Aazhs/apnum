import ApnumLink
import SwiftUI

/// Recent conversations on the left, the selected thread and a reply field on the right.
struct PhoneMessagesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skyTheme) private var theme
    @State private var selected: String?
    /// The thread as last fetched from the phone (older history). Live messages come from `model.phone.messages`.
    @State private var fetched: [PhoneSMS] = []
    @State private var sentCount = 0
    @State private var draft = ""
    @State private var sending = false

    private struct Conversation: Identifiable {
        let address: String
        let latest: PhoneSMS
        var id: String { address }
    }

    private var conversations: [Conversation] {
        Dictionary(grouping: model.phone.messages, by: \.address)
            .compactMap { address, messages in
                messages.max { $0.date < $1.date }.map { Conversation(address: address, latest: $0) }
            }
            .sorted { $0.latest.date > $1.latest.date }
    }

    /// Fetched history plus everything the phone pushed since, so a new message shows without waiting for a re-fetch.
    private var thread: [PhoneSMS] {
        guard let selected else { return [] }
        var byID: [String: PhoneSMS] = [:]
        for message in fetched { byID[message.id] = message }
        for message in model.phone.messages where message.address == selected { byID[message.id] = message }
        return byID.values.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeading("Messages")
            if conversations.isEmpty {
                Text("No messages yet. New ones appear here as they arrive.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 240)
                    Divider()
                    threadView
                }
                .frame(height: 340)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .skyPanel(theme)
        .onAppear { if selected == nil { selected = conversations.first?.address } }
        .onChange(of: conversations.first?.address) { _, first in if selected == nil { selected = first } }
        .task(id: ThreadKey(address: selected, sent: sentCount)) {
            guard let selected else { fetched = []; return }
            fetched = await model.phoneThread(address: selected)
        }
    }

    private struct ThreadKey: Equatable {
        var address: String?
        var sent: Int
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(conversations) { conversation in
                    Button { selected = conversation.address } label: { row(conversation) }
                        .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let isSelected = selected == conversation.address
        return HStack(spacing: 10) {
            Text(String(conversation.latest.title.first(where: \.isLetter) ?? conversation.latest.title.first ?? "#").uppercased())
                .font(.callout.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.raised.opacity(theme.isActive ? 0.8 : 0.35)))
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(conversation.latest.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(PhoneTime.short(conversation.latest.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text(conversation.latest.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(theme.isActive ? theme.raised.opacity(0.6) : Color.primary.opacity(0.1)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
    }

    @ViewBuilder
    private var threadView: some View {
        if let selected {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(thread) { message in
                                bubble(message).id(message.id)
                            }
                        }
                        .padding(14)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: thread.count) { if let last = thread.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                Divider()
                replyBar(to: selected)
            }
        } else {
            Text("Select a conversation").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bubble(_ message: PhoneSMS) -> some View {
        HStack {
            if !message.incoming { Spacer(minLength: 40) }
            VStack(alignment: message.incoming ? .leading : .trailing, spacing: 2) {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(message.incoming ? Color.primary : Color.white)
                    .background(
                        message.incoming
                            ? AnyShapeStyle(theme.isActive ? theme.raised.opacity(0.8) : Color.primary.opacity(0.1))
                            : AnyShapeStyle(theme.isActive ? theme.accent : Color.accentColor),
                        in: .rect(cornerRadius: 16, style: .continuous))
                Text(message.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            if message.incoming { Spacer(minLength: 40) }
        }
    }

    private func replyBar(to address: String) -> some View {
        let canReply = PhoneNumber.isDialable(address)
        return VStack(spacing: 6) {
            if !canReply {
                Text("You can't reply to this sender.").font(.caption).foregroundStyle(.secondary)
            }
            replyFields(to: address, canReply: canReply)
        }
        .padding(10)
    }

    private func replyFields(to address: String, canReply: Bool) -> some View {
        HStack(spacing: 8) {
            TextField("Reply", text: $draft)
                .disabled(!canReply)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(theme.isActive ? theme.raised.opacity(0.5) : Color.primary.opacity(0.07)))
                .onSubmit { send(to: address) }
            Button("Send") { send(to: address) }
                .buttonStyle(.pill(theme.isActive ? theme.accent : .accentColor))
                .disabled(!canReply || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !model.hasTool("phone.sms.send"))
        }
    }

    private func send(to address: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, PhoneNumber.isDialable(address) else { return }
        sending = true
        Task {
            if await model.run("phone.sms.send", ["to": .string(address), "body": .string(text)]) != nil {
                draft = ""
                await model.refreshPhone()
                sentCount += 1
            }
            sending = false
        }
    }
}
