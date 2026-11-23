//
//  ContentView.swift
//  OpenLearn
//
//  Created by Abdullah  on 23/11/2026.
//

import SwiftUI
import Combine

// MARK: - Sidebar selection
enum SidebarTab: String, Hashable, CaseIterable {
    case chatbox = "AI Chatbox"
    case studySets = "Study Sets"
    case graphing = "Math & Graphing"

    var icon: String {
        switch self {
        case .chatbox: return "bubble.left.and.bubble.right.fill"
        case .studySets: return "folder.fill"
        case .graphing: return "chart.xyaxis.line"
        }
    }
}

enum SidebarItem: Hashable {
    case tab(SidebarTab)
    case thread(UUID)
}

// MARK: - Data models
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var text: String
    var isUser: Bool
    var isError = false
    var timestamp = Date()
}

struct Subject: Identifiable, Codable {
    var id = UUID()
    var name: String
}

struct ChatThread: Identifiable, Codable {
    var id = UUID()
    var title = "New chat"
    var subjectID: UUID? = nil
    var messages: [ChatMessage] = [
        ChatMessage(
            text: "Hello! I'm your OpenLearn AI Chatbox. Ask me any study question or paste your notes!",
            isUser: false
        )
    ]
    var updatedAt = Date()
}

private struct SavedState: Codable {
    var threads: [ChatThread]
    var subjects: [Subject]
}

// MARK: - Store (all chats and subjects, saved to disk)
@MainActor
final class ChatStore: ObservableObject {
    @Published var threads: [ChatThread] = []
    @Published var subjects: [Subject] = []
    @Published var currentThreadID = UUID()
    @Published var loadingThreadIDs: Set<UUID> = []

    private let service: GeminiService
    private let fileURL: URL

    init(apiKey: String) {
        service = GeminiService(apiKey: apiKey)

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenLearn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("chats.json")

        load()
        importOldChatIfNeeded()
        if threads.isEmpty { threads = [ChatThread()] }
        currentThreadID = mostRecentThreadID()
    }

    // MARK: Lookups
    var recentThreads: [ChatThread] {
        threads.filter { $0.subjectID == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func threads(in subjectID: UUID) -> [ChatThread] {
        threads.filter { $0.subjectID == subjectID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func thread(_ id: UUID) -> ChatThread? {
        threads.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        threads.firstIndex { $0.id == id }
    }

    private func mostRecentThreadID() -> UUID {
        threads.max(by: { $0.updatedAt < $1.updatedAt })?.id ?? UUID()
    }

    // MARK: Threads
    @discardableResult
    func newThread(subjectID: UUID? = nil) -> UUID {
        // Reuse an empty chat instead of piling up blank ones
        if let empty = threads.first(where: { $0.messages.count <= 1 }),
           let i = index(of: empty.id) {
            threads[i].subjectID = subjectID
            currentThreadID = empty.id
            save()
            return empty.id
        }
        let thread = ChatThread(subjectID: subjectID)
        threads.insert(thread, at: 0)
        currentThreadID = thread.id
        save()
        return thread.id
    }

    func deleteThread(_ id: UUID) {
        threads.removeAll { $0.id == id }
        loadingThreadIDs.remove(id)
        if threads.isEmpty { threads = [ChatThread()] }
        if !threads.contains(where: { $0.id == currentThreadID }) {
            currentThreadID = mostRecentThreadID()
        }
        save()
    }

    func move(_ threadID: UUID, to subjectID: UUID?) {
        guard let i = index(of: threadID) else { return }
        threads[i].subjectID = subjectID
        save()
    }

    // MARK: Subjects
    func addSubject(_ name: String) {
        subjects.append(Subject(name: name))
        save()
    }

    func deleteSubject(_ id: UUID) {
        for i in threads.indices where threads[i].subjectID == id {
            threads[i].subjectID = nil
        }
        subjects.removeAll { $0.id == id }
        save()
    }

    // MARK: Sending
    func send(_ text: String, in threadID: UUID) {
        guard let i = index(of: threadID), !loadingThreadIDs.contains(threadID) else { return }

        threads[i].messages.append(ChatMessage(text: text, isUser: true))
        if threads[i].title == "New chat" {
            threads[i].title = Self.makeTitle(text)
        }
        threads[i].updatedAt = Date()
        loadingThreadIDs.insert(threadID)
        save()

        let history = buildHistory(from: threads[i].messages)

        Task {
            let reply: ChatMessage
            do {
                let responseText = try await service.send(history: history)
                reply = ChatMessage(text: responseText, isUser: false)
            } catch {
                reply = ChatMessage(text: error.localizedDescription, isUser: false, isError: true)
            }

            if let j = index(of: threadID) {
                threads[j].messages.append(reply)
                threads[j].updatedAt = Date()
            }
            loadingThreadIDs.remove(threadID)
            save()
        }
    }

    /// Skips the greeting and error bubbles, and merges back-to-back messages
    /// from the same side (happens after a failed send).
    private func buildHistory(from messages: [ChatMessage]) -> [GeminiMessage] {
        var history: [GeminiMessage] = []
        for message in messages.dropFirst() where !message.isError {
            let role = message.isUser ? "user" : "model"
            if let last = history.last, last.role == role {
                history[history.count - 1] = GeminiMessage(role: role, text: last.text + "\n\n" + message.text)
            } else {
                history.append(GeminiMessage(role: role, text: message.text))
            }
        }
        return history
    }

    private static func makeTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 32 ? String(clean.prefix(32)) + "…" : clean
    }

    // MARK: Saving and loading
    private func save() {
        var cleaned = threads
        for i in cleaned.indices {
            cleaned[i].messages.removeAll { $0.isError }   // error bubbles are not saved
        }
        let state = SavedState(threads: cleaned, subjects: subjects)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        threads = state.threads
        subjects = state.subjects
    }

    /// Moves the single chat from the earlier version of the app into the first thread.
    private func importOldChatIfNeeded() {
        guard threads.isEmpty,
              let data = UserDefaults.standard.data(forKey: "savedChatHistory"),
              let old = try? JSONDecoder().decode([ChatMessage].self, from: data),
              old.count > 1 else { return }

        var thread = ChatThread()
        thread.messages = old
        if let firstUser = old.first(where: { $0.isUser }) {
            thread.title = Self.makeTitle(firstUser.text)
        }
        threads = [thread]
        UserDefaults.standard.removeObject(forKey: "savedChatHistory")
        save()
    }
}

// MARK: - Main Dashboard with Sidebar
struct ContentView: View {
    var onReset: () -> Void

    @StateObject private var store: ChatStore
    @State private var selection: SidebarItem? = .tab(.chatbox)
    @State private var expandedSubjects: Set<UUID> = []
    @State private var showAddSubject = false
    @State private var newSubjectName = ""

    init(apiKey: String, onReset: @escaping () -> Void) {
        self.onReset = onReset
        _store = StateObject(wrappedValue: ChatStore(apiKey: apiKey))
    }

    // The chat shown on the right
    private var chatThreadID: UUID {
        if case .thread(let id)? = selection, store.thread(id) != nil {
            return id
        }
        return store.currentThreadID
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            switch selection {
            case .tab(.studySets)?:
                StudySetsView()
            case .tab(.graphing)?:
                MathGraphingView()
            default:
                MainChatView(store: store, threadID: chatThreadID)
                    .id(chatThreadID)
            }
        }
        .onChange(of: selection) { _, newValue in
            if case .thread(let id)? = newValue {
                store.currentThreadID = id
            }
        }
        .sheet(isPresented: $showAddSubject) {
            addSubjectSheet
        }
    }

    // MARK: Sidebar
    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(SidebarItem.tab(tab))
                }
            }

            Section {
                if store.subjects.isEmpty {
                    Text("No subjects yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(store.subjects) { subject in
                    DisclosureGroup(isExpanded: expandedBinding(for: subject.id)) {
                        let items = store.threads(in: subject.id)
                        if items.isEmpty {
                            Text("No chats yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ForEach(items) { thread in
                            threadRow(thread)
                        }
                    } label: {
                        Label(subject.name, systemImage: "book.closed")
                            .contextMenu {
                                Button("New chat in \(subject.name)") {
                                    startNewChat(in: subject.id)
                                }
                                Divider()
                                Button("Delete subject", role: .destructive) {
                                    store.deleteSubject(subject.id)
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Subjects")
                    Spacer()
                    Button {
                        newSubjectName = ""
                        showAddSubject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Add a subject")
                }
            }

            Section {
                ForEach(store.recentThreads) { thread in
                    threadRow(thread)
                }
            } header: {
                HStack {
                    Text("Recent threads · \(store.threads.count)")
                    Spacer()
                    Button {
                        startNewChat(in: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New chat")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OpenLearn")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset Onboarding / API Key")
            }
        }
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        HStack(spacing: 6) {
            Text(thread.title)
                .lineLimit(1)
            if store.loadingThreadIDs.contains(thread.id) {
                Spacer()
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .tag(SidebarItem.thread(thread.id))
        .contextMenu {
            Menu("Move to subject") {
                Button("No subject") { store.move(thread.id, to: nil) }
                ForEach(store.subjects) { subject in
                    Button(subject.name) { store.move(thread.id, to: subject.id) }
                }
            }
            Divider()
            Button("Delete chat", role: .destructive) {
                deleteThread(thread.id)
            }
        }
    }

    private var addSubjectSheet: some View {
        VStack(spacing: 16) {
            Text("New subject")
                .font(.headline)

            TextField("e.g. Calculus, Biology, History", text: $newSubjectName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addSubject() }

            HStack {
                Button("Cancel") {
                    showAddSubject = false
                }
                .buttonStyle(.bordered)

                Button("Add") {
                    addSubject()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(newSubjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    // MARK: Actions
    private func addSubject() {
        let name = newSubjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addSubject(name)
        showAddSubject = false
    }

    private func startNewChat(in subjectID: UUID?) {
        let id = store.newThread(subjectID: subjectID)
        if let subjectID {
            expandedSubjects.insert(subjectID)
        }
        selection = .thread(id)
    }

    private func deleteThread(_ id: UUID) {
        store.deleteThread(id)
        if case .thread(let selected)? = selection, selected == id {
            selection = .thread(store.currentThreadID)
        }
    }

    private func expandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedSubjects.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedSubjects.insert(id)
                } else {
                    expandedSubjects.remove(id)
                }
            }
        )
    }
}

// MARK: - 1. AI Chatbox Section
struct MainChatView: View {
    @ObservedObject var store: ChatStore
    let threadID: UUID

    @State private var inputText = ""

    private var thread: ChatThread? { store.thread(threadID) }
    private var messages: [ChatMessage] { thread?.messages ?? [] }
    private var isLoading: Bool { store.loadingThreadIDs.contains(threadID) }

    private var subjectName: String {
        if let subjectID = thread?.subjectID,
           let subject = store.subjects.first(where: { $0.id == subjectID }) {
            return subject.name
        }
        return "No subject"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(messages) { message in
                            HStack {
                                if message.isUser { Spacer() }

                                VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                                    Text(rendered(message.text))
                                        .padding(12)
                                        .background(bubbleColor(message))
                                        .foregroundColor(message.isUser ? .white : .primary)
                                        .cornerRadius(14)
                                        .textSelection(.enabled)

                                    Text(message.timestamp, style: .time)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: 550, alignment: message.isUser ? .trailing : .leading)

                                if !message.isUser { Spacer() }
                            }
                            .padding(.horizontal)
                        }

                        if isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding(.vertical)
                }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: messages.count) { scrollToBottom(proxy) }
                .onChange(of: isLoading) { scrollToBottom(proxy) }
            }

            Divider()

            HStack(spacing: 12) {
                TextField("Ask the AI Chatbox...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(
                    inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading
                )
            }
            .padding()
        }
        .navigationTitle(thread?.title ?? "AI Chatbox")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("No subject") {
                        store.move(threadID, to: nil)
                    }
                    if !store.subjects.isEmpty {
                        Divider()
                    }
                    ForEach(store.subjects) { subject in
                        Button(subject.name) {
                            store.move(threadID, to: subject.id)
                        }
                    }
                } label: {
                    Label(subjectName, systemImage: "tag")
                }
                .help("Move this chat to a subject")
            }
            ToolbarItem(placement: .automatic) {
                ModelPickerMenu()
            }
        }
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }
        inputText = ""
        store.send(trimmed, in: threadID)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            if isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        if animated {
            withAnimation { action() }
        } else {
            action()
        }
    }

    private func bubbleColor(_ message: ChatMessage) -> Color {
        if message.isError { return Color.red.opacity(0.2) }
        return message.isUser ? Color.indigo : Color.secondary.opacity(0.15)
    }

    // Renders **bold**, *italic*, `code` and links
    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - 2. Study Sets Section
struct StudySetsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.indigo)
            Text("Your Study Sets")
                .font(.title2)
                .fontWeight(.bold)
            Text("Create local flashcards and topic folders stored directly on your Mac.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Study Sets")
    }
}

// MARK: - 3. Math & Graphing Section
struct MathGraphingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundColor(.indigo)
            Text("Math & Equation Grapher")
                .font(.title2)
                .fontWeight(.bold)
            Text("Test slope-intercept forms, intercepts, and linear equations interactively.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Math & Graphing")
    }
}
