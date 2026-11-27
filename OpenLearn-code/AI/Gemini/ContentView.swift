//
//  ContentView.swift
//  OpenLearn
//
//  Created by Abdullah  on 23/11/2026.
//

import SwiftUI
import Combine

// MARK: - Sections in the top bar
enum WorkspaceTab: String, Hashable, CaseIterable {
    case chatbox = "Chatbox"
    case studySets = "Study Sets"
    case graphing = "Graphing"
}

// MARK: - Data models
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var text: String
    var isUser: Bool
    var isError = false
    var timestamp = Date()
    var topic: String? = nil
    var cards: [Flashcard]? = nil
    var setName: String? = nil      // study set the cards were saved to
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
            text: "Hello! I'm your OpenLearn AI Chatbox. Ask me any study question, paste your notes or attach a file.",
            isUser: false
        )
    ]
    var updatedAt = Date()
    var attachments: [MaterialFile]? = nil   // optional, so chats saved earlier still load

    var files: [MaterialFile] { attachments ?? [] }
    var isBlank: Bool { messages.count <= 1 && files.isEmpty }
}

private struct SavedState: Codable {
    var threads: [ChatThread]
    var subjects: [Subject]
}

// MARK: - Study answers
/// Splits the AI's reply into a topic label, the answer itself and any flashcards.
struct StudyAnswer {
    let topic: String?
    let text: String
    let cards: [Flashcard]

    private struct Card: Decodable {
        let front: String
        let back: String
    }

    init(_ raw: String) {
        var body = raw
        var found: [Flashcard] = []
        var label: String? = nil

        // The flashcards arrive as a fenced block of JSON at the end
        for tag in ["```cards", "```json"] {
            guard let start = body.range(of: tag, options: .backwards) else { continue }
            let rest = body[start.upperBound...]
            let close = rest.range(of: "```")
            let json = String(rest[..<(close?.lowerBound ?? rest.endIndex)])
            let decoded = (try? JSONDecoder().decode([Card].self, from: Data(json.utf8))) ?? []
            if decoded.isEmpty && tag == "```json" { continue }     // ordinary code: leave it

            for card in decoded {
                let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
                let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
                if !front.isEmpty && !back.isEmpty {
                    found.append(Flashcard(front: front, back: back))
                }
            }
            body.removeSubrange(start.lowerBound..<(close?.upperBound ?? body.endIndex))
            break
        }

        var lines = body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let first = lines.first {
            let plain = first.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if plain.uppercased().hasPrefix("TOPIC:") {
                let name = plain.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { label = name }
                lines.removeFirst()
            }
        }

        var cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = found.isEmpty ? raw : "Here are your flashcards."
        }

        topic = label
        text = cleaned
        cards = found
    }
}

// MARK: - Store (all chats and subjects, saved to disk)
@MainActor
final class ChatStore: ObservableObject {
    @Published var threads: [ChatThread] = []
    @Published var subjects: [Subject] = []
    @Published var currentThreadID = UUID()
    @Published var loadingThreadIDs: Set<UUID> = []
    @Published var fileNotices: [UUID: String] = [:]

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
    /// Newest first. Pass nil for chats without a subject.
    func threads(in subjectID: UUID?) -> [ChatThread] {
        threads.filter { $0.subjectID == subjectID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func subjectName(_ subjectID: UUID?) -> String {
        subjects.first(where: { $0.id == subjectID })?.name ?? "General"
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
        if let i = threads.firstIndex(where: { $0.isBlank && ($0.subjectID == subjectID || $0.subjectID == nil) }) {
            threads[i].subjectID = subjectID
            currentThreadID = threads[i].id
            save()
            return threads[i].id
        }
        let thread = ChatThread(subjectID: subjectID)
        threads.insert(thread, at: 0)
        currentThreadID = thread.id
        save()
        return thread.id
    }

    func deleteThread(_ id: UUID) {
        let subjectID = thread(id)?.subjectID
        thread(id)?.files.forEach { FileImporter.deleteStoredFile(for: $0) }
        threads.removeAll { $0.id == id }
        loadingThreadIDs.remove(id)
        fileNotices[id] = nil
        if !threads.contains(where: { $0.id == currentThreadID }) {
            if let next = threads(in: subjectID).first {
                currentThreadID = next.id
            } else {
                newThread(subjectID: subjectID)
            }
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

    // MARK: Files
    func addFiles(_ urls: [URL], to threadID: UUID) {
        var problems: [String] = []

        for url in urls {
            do {
                let file = try FileImporter.importFile(at: url)
                guard let i = index(of: threadID) else { return }
                threads[i].attachments = threads[i].files + [file]
                threads[i].updatedAt = Date()
            } catch {
                problems.append(error.localizedDescription)
            }
        }

        fileNotices[threadID] = problems.isEmpty ? nil : problems.joined(separator: "\n")
        save()
    }

    func removeFile(_ fileID: UUID, from threadID: UUID) {
        guard let i = index(of: threadID) else { return }
        if let file = threads[i].files.first(where: { $0.id == fileID }) {
            FileImporter.deleteStoredFile(for: file)
        }
        threads[i].attachments = threads[i].files.filter { $0.id != fileID }
        fileNotices[threadID] = nil
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

        var history = buildHistory(from: threads[i].messages)
        let skipped = attach(threads[i].files, to: &history)
        fileNotices[threadID] = skipped.isEmpty
            ? nil
            : "Skipped (too large or unreadable): \(skipped.joined(separator: ", "))"

        addAnswerStyle(to: &history)

        let request = history
        Task {
            var reply: ChatMessage
            do {
                let responseText = try await service.send(history: request)
                let answer = StudyAnswer(responseText)
                reply = ChatMessage(text: answer.text, isUser: false)
                reply.topic = answer.topic
                if !answer.cards.isEmpty, let j = index(of: threadID) {
                    let setName = subjectName(threads[j].subjectID)
                    saveCards(answer.cards, toSetNamed: setName)
                    reply.cards = answer.cards
                    reply.setName = setName
                }
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

    /// Adds the chat's files to the newest question. Images and PDFs go as they are,
    /// other files go as text. Returns the names of any files that were left out.
    private func attach(_ files: [MaterialFile], to history: inout [GeminiMessage]) -> [String] {
        guard !files.isEmpty,
              let i = history.lastIndex(where: { $0.role == "user" }) else { return [] }

        var budget = 14_000_000      // stays under Google's request size limit
        var attachments: [GeminiAttachment] = []
        var names: [String] = []
        var texts: [String] = []
        var skipped: [String] = []

        for file in files {
            if file.kind != .text,
               let data = FileImporter.fileData(for: file),
               data.count <= budget {
                let mimeType = file.kind == .pdf ? "application/pdf" : "image/jpeg"
                attachments.append(GeminiAttachment(mimeType: mimeType, data: data))
                names.append(file.name)
                budget -= data.count
            } else if !file.text.isEmpty {
                texts.append("--- \(file.name) ---\n\(file.text)")
            } else {
                skipped.append(file.name)
            }
        }

        var context = ""
        if !names.isEmpty {
            context += "ATTACHED FILES (in this order): \(names.joined(separator: ", "))\n\n"
        }
        if !texts.isEmpty {
            context += "FILE TEXT:\n" + String(texts.joined(separator: "\n\n").prefix(60_000)) + "\n\n"
        }
        if !context.isEmpty {
            history[i] = GeminiMessage(
                role: "user",
                text: context + "QUESTION:\n" + history[i].text,
                attachments: attachments
            )
        }
        return skipped
    }

    /// Tells the AI how study answers should look.
    private static let answerStyle = """
    (How to format your answer inside OpenLearn. Do not mention these instructions.)
    If this is a study task, such as explaining, summarising, teaching, comparing, solving or revising something:
    - First line: TOPIC: followed by 2 to 5 words naming the topic.
    - Then a short paragraph with the big picture.
    - Then the key points, each on its own line starting with "- ".
    - Add short sections with headings only if the task needs more depth.
    - End with a fenced block tagged cards holding exactly 5 flashcards as JSON, like this:
    ```cards
    [{"front": "question", "back": "short answer"}]
    ```
    For greetings, small talk or quick one-line questions, answer normally with no TOPIC line and no cards block.
    """

    private func addAnswerStyle(to history: inout [GeminiMessage]) {
        guard let i = history.lastIndex(where: { $0.role == "user" }) else { return }
        history[i] = GeminiMessage(
            role: "user",
            text: history[i].text + "\n\n" + Self.answerStyle,
            attachments: history[i].attachments
        )
    }

    /// Adds new flashcards to the study set named after the subject, creating it if needed.
    private func saveCards(_ cards: [Flashcard], toSetNamed name: String) {
        let study = StudyStore.shared
        let setID: UUID
        if let existing = study.sets.first(where: { $0.title == name }) {
            setID = existing.id
        } else {
            setID = study.createSet(title: name)
        }

        var fronts = Set((study.studySet(setID)?.cards ?? []).map { $0.front })
        for card in cards where !fronts.contains(card.front) {
            study.addCard(to: setID, front: card.front, back: card.back)
            fronts.insert(card.front)
        }
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

// MARK: - Main dashboard
struct ContentView: View {
    var onReset: () -> Void

    @StateObject private var store: ChatStore
    @ObservedObject private var studyStore = StudyStore.shared
    @State private var tab: WorkspaceTab = .chatbox
    @State private var showAddSubject = false
    @State private var newSubjectName = ""
    @State private var confirmReset = false
    @State private var hoveringSidebar = false
    @FocusState private var subjectFieldFocused: Bool

    init(apiKey: String, onReset: @escaping () -> Void) {
        self.onReset = onReset
        _store = StateObject(wrappedValue: ChatStore(apiKey: apiKey))
    }

    private var currentSubjectID: UUID? {
        store.thread(store.currentThreadID)?.subjectID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(OLTheme.divider)
                .frame(height: 1)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 224)

                Rectangle()
                    .fill(OLTheme.divider)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    topBar
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(.easeInOut(duration: 0.25), value: tab)
                }
            }
        }
        .background(OLTheme.background)
        .sheet(isPresented: $showAddSubject) {
            addSubjectSheet
        }
        .confirmationDialog("Reset and sign out?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset and sign out", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your API key from the Keychain. Your chats and study sets stay on this Mac.")
        }
    }

    // MARK: Header
    private var header: some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: "lock")
                Text("OpenLearn — Study Workspace")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(OLTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .olPanel(radius: 11, fill: OLTheme.surfaceLow, border: OLTheme.borderSoft)

            HStack(spacing: 7) {
                Spacer()
                Circle()
                    .fill(OLTheme.green)
                    .frame(width: 6, height: 6)
                OLEyebrow("Local", color: OLTheme.green)
            }
            .padding(.trailing, 22)
        }
        .frame(height: 52)
    }

    // MARK: Top bar (sections on the left, chat options on the right)
    private var topBar: some View {
        HStack(spacing: 10) {
            tabSwitcher

            Spacer(minLength: 8)

            if tab == .chatbox {
                subjectMenu
                ModelPickerMenu()
            }

            moreMenu
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tab == item ? OLTheme.textBright : OLTheme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(
                            tab == item ? OLTheme.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .olPanel(radius: 12, fill: OLTheme.surfaceLow)
        .fixedSize()
        .animation(.easeOut(duration: 0.18), value: tab)
    }

    private var subjectMenu: some View {
        let name = store.subjectName(currentSubjectID)
        let shortName = name.count > 18 ? String(name.prefix(17)) + "…" : name

        return Menu {
            Button("General") {
                store.move(store.currentThreadID, to: nil)
            }
            ForEach(store.subjects) { subject in
                Button(subject.name) {
                    store.move(store.currentThreadID, to: subject.id)
                }
            }
            Divider()
            Button("New subject…") {
                askForSubject()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(OLTheme.accentSoft)
                Text(shortName)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(OLTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .olPanel(radius: 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move this chat to a subject")
    }

    /// Older chats, delete and sign out live here, so the sidebar stays clean.
    private var moreMenu: some View {
        Menu {
            if tab == .chatbox {
                Section("Chats in \(store.subjectName(currentSubjectID))") {
                    ForEach(store.threads(in: currentSubjectID)) { thread in
                        Button {
                            store.currentThreadID = thread.id
                        } label: {
                            if thread.id == store.currentThreadID {
                                Label(thread.title, systemImage: "checkmark")
                            } else {
                                Text(thread.title)
                            }
                        }
                    }
                }
                Button("Delete this chat", role: .destructive) {
                    store.deleteThread(store.currentThreadID)
                }
                Divider()
            }
            Button("Reset key & sign out", role: .destructive) {
                confirmReset = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OLTheme.textSecondary)
                .frame(width: 16, height: 15)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .olPanel(radius: 10)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chats and account")
    }

    // MARK: Detail
    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .chatbox:
            MainChatView(
                store: store,
                threadID: store.currentThreadID,
                onOpenStudySets: { tab = .studySets }
            )
            .id(store.currentThreadID)
            .transition(.opacity)
        case .studySets:
            StudySetsView()
                .transition(.opacity)
        case .graphing:
            MathGraphingView()
                .transition(.opacity)
        }
    }

    // MARK: Sidebar
    /// Chats without a subject. An untouched empty chat only counts while it's open.
    private var generalThreads: [ChatThread] {
        store.threads(in: nil).filter { !$0.isBlank || $0.id == store.currentThreadID }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        OLEyebrow("Subjects")
                        Spacer()
                        Button {
                            askForSubject()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OLTheme.textMuted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(hoveringSidebar || store.subjects.isEmpty ? 1 : 0)
                        .help("Add a subject")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    ForEach(store.subjects) { subject in
                        subjectRow(subject.name, id: subject.id, count: store.threads(in: subject.id).count)
                            .contextMenu {
                                Button("Delete subject", role: .destructive) {
                                    store.deleteSubject(subject.id)
                                }
                            }
                    }

                    if !generalThreads.isEmpty {
                        subjectRow("General", id: nil, count: generalThreads.count)
                    }

                    newThreadButton
                        .padding(.top, 8)
                }
                .padding(14)
            }

            weekCard
                .padding(14)
        }
        .contentShape(Rectangle())
        .onHover { hoveringSidebar = $0 }
    }

    private func subjectRow(_ title: String, id: UUID?, count: Int) -> some View {
        SubjectRow(
            title: title,
            count: count,
            selected: tab == .chatbox && currentSubjectID == id,
            busy: store.threads(in: id).contains { store.loadingThreadIDs.contains($0.id) }
        ) {
            showSubject(id)
        }
    }

    private var newThreadButton: some View {
        Button {
            tab = .chatbox
            store.newThread(subjectID: currentSubjectID)
        } label: {
            Label("New thread", systemImage: "plus")
                .font(.system(size: 13))
                .foregroundStyle(OLTheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(OLTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: This week
    private var weekAgo: Date { Date().addingTimeInterval(-7 * 86_400) }

    private var threadsThisWeek: Int {
        store.threads.filter { thread in
            thread.updatedAt > weekAgo && thread.messages.contains { $0.isUser }
        }.count
    }

    private var documentsThisWeek: Int {
        var total = 0
        for thread in store.threads where thread.updatedAt > weekAgo {
            total += thread.files.count
        }
        for item in studyStore.sets where item.updatedAt > weekAgo {
            total += item.files.count + item.syllabusFiles.count
        }
        return total
    }

    private var weekCard: some View {
        let reviewed = studyStore.reviewsThisWeek
        let threads = threadsThisWeek
        let documents = documentsThisWeek

        return VStack(alignment: .leading, spacing: 6) {
            OLEyebrow("This week")
            Text("\(reviewed) flashcard\(reviewed == 1 ? "" : "s") reviewed")
                .font(.system(size: 12.5))
                .foregroundStyle(OLTheme.textBody)
            Text("\(threads) thread\(threads == 1 ? "" : "s"), \(documents) document\(documents == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(OLTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .olPanel(radius: 14, fill: OLTheme.surfaceLow, border: OLTheme.borderSoft)
    }

    // MARK: Add subject
    private var addSubjectSheet: some View {
        VStack(spacing: 16) {
            Text("New subject")
                .font(.headline)

            TextField("e.g. Calculus, Biology, History", text: $newSubjectName)
                .textFieldStyle(.plain)
                .focused($subjectFieldFocused)
                .onSubmit { addSubject() }
                .olField(focused: subjectFieldFocused)

            HStack {
                Button("Cancel") {
                    showAddSubject = false
                }
                .buttonStyle(.olGhost)

                Button("Add") {
                    addSubject()
                }
                .buttonStyle(.olAccent)
                .disabled(newSubjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
        .background(OLTheme.surface)
        .onAppear { subjectFieldFocused = true }
    }

    // MARK: Actions
    private func askForSubject() {
        newSubjectName = ""
        showAddSubject = true
    }

    private func addSubject() {
        let name = newSubjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addSubject(name)
        showAddSubject = false
        if let added = store.subjects.last {
            showSubject(added.id)
        }
    }

    /// Opens the latest chat in a subject, or starts one.
    private func showSubject(_ subjectID: UUID?) {
        tab = .chatbox
        guard currentSubjectID != subjectID else { return }
        if let latest = store.threads(in: subjectID).first {
            store.currentThreadID = latest.id
        } else {
            store.newThread(subjectID: subjectID)
        }
    }
}

private struct SubjectRow: View {
    let title: String
    let count: Int
    let selected: Bool
    let busy: Bool
    var action: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if selected { return OLTheme.selection }
        return hovering ? Color.white.opacity(0.04) : Color.clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? OLTheme.textBright : OLTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if busy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("\(count) thread\(count == 1 ? "" : "s")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(OLTheme.textFaint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - 1. AI Chatbox section
struct MainChatView: View {
    @ObservedObject var store: ChatStore
    let threadID: UUID
    var onOpenStudySets: () -> Void

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    private var thread: ChatThread? { store.thread(threadID) }
    private var messages: [ChatMessage] { thread?.messages ?? [] }
    private var files: [MaterialFile] { thread?.files ?? [] }
    private var isLoading: Bool { store.loadingThreadIDs.contains(threadID) }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            if !files.isEmpty {
                fileStrip
            }
            messageList

            if let notice = store.fileNotices[threadID] {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(OLTheme.amber)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }

            inputBar
        }
        .onAppear { inputFocused = true }
    }

    // MARK: Attached files
    private var fileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    OLFileChip(name: file.name, onRemove: { store.removeFile(file.id, from: threadID) })
                }
            }
            .padding(.vertical, 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: Messages
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            label: thread?.subjectID == nil ? "OpenLearn" : store.subjectName(thread?.subjectID),
                            onOpenStudySets: onOpenStudySets
                        )
                        .id(message.id)
                        .transition(.opacity.combined(with: .offset(y: 14)))
                    }

                    if isLoading {
                        HStack(spacing: 10) {
                            OLTypingDots()
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundStyle(OLTheme.textMuted)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .olPanel(radius: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("loading")
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: messages.count)
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: messages.count) { scrollToBottom(proxy) }
            .onChange(of: isLoading) { scrollToBottom(proxy) }
        }
    }

    // MARK: Input
    private var inputBar: some View {
        HStack(spacing: 12) {
            Button(action: pickFiles) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14))
                    .foregroundStyle(OLTheme.textMuted)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Attach files")

            TextField("", text: $inputText, prompt: Text("Ask anything about your PDFs and slides...").foregroundColor(OLTheme.textMuted))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(OLTheme.textPrimary)
                .focused($inputFocused)
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(OLTheme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: canSend)
        }
        .padding(.leading, 14)
        .padding(.trailing, 11)
        .padding(.vertical, 11)
        .olPanel(radius: 16, border: inputFocused ? OLTheme.accent.opacity(0.6) : OLTheme.border)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: Actions
    private func pickFiles() {
        let urls = FilePicker.pick(message: "Choose files to ask about")
        if !urls.isEmpty {
            store.addFiles(urls, to: threadID)
        }
        inputFocused = true
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
}

// MARK: - Message bubbles
private struct MessageRow: View {
    let message: ChatMessage
    let label: String
    var onOpenStudySets: () -> Void

    private var time: String {
        message.timestamp.formatted(date: .omitted, time: .shortened)
    }

    private var cards: [Flashcard] { message.cards ?? [] }

    private var heading: String {
        if message.isError { return "Something went wrong · \(time)" }
        return message.topic ?? "\(label) · \(time)"
    }

    var body: some View {
        if message.isUser {
            Text(inlineMarkdown(message.text))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                .background(OLTheme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: OLTheme.indigo.opacity(0.35), radius: 16, y: 8)
                .help(time)
                .frame(maxWidth: 580, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 70)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                answer
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.trailing, 40)

                if !cards.isEmpty {
                    CardStrip(cards: Array(cards.prefix(3)))
                        .frame(maxWidth: 880)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 12) {
            OLEyebrow(heading, color: message.isError ? OLTheme.rose : OLTheme.textMuted)

            ReplyText(text: message.text)

            if !cards.isEmpty, let setName = message.setName {
                Button(action: onOpenStudySets) {
                    readyLine(setName)
                }
                .buttonStyle(.plain)
                .help("Open Study Sets")
            }
        }
        .frame(maxWidth: cards.isEmpty ? nil : .infinity, alignment: .leading)
        .padding(18)
        .olPanel(
            radius: 16,
            fill: message.isError ? OLTheme.rose.opacity(0.08) : OLTheme.surface,
            border: message.isError ? OLTheme.rose.opacity(0.35) : OLTheme.border
        )
    }

    private func readyLine(_ setName: String) -> some View {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        let count = cards.count
        let amount = count < words.count ? words[count] : "\(count)"
        let lead = "\(amount) flashcard\(count == 1 ? " is" : "s are") ready in"

        return HStack(spacing: 7) {
            Image(systemName: "sparkles")
            Text("\(lead) \(Text(setName).font(.system(size: 13, design: .monospaced))).")
        }
        .font(.system(size: 13.5))
        .foregroundStyle(Color(olRGB: 0xC5D0FC))
        .contentShape(Rectangle())
    }
}

/// A row of flashcard previews under a study answer.
private struct CardStrip: View {
    let cards: [Flashcard]

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                VStack(alignment: .leading, spacing: 8) {
                    OLEyebrow("Card \(index + 1)")
                    Text(card.front)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(OLTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.back)
                        .font(.system(size: 12))
                        .foregroundStyle(OLTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .olPanel(radius: 14, fill: OLTheme.surfaceLow, border: OLTheme.borderSoft)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Renders **bold**, *italic*, `code` and links
private func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

/// An AI answer: headings, ticked bullet points, code blocks and paragraphs.
private struct ReplyText: View {
    let text: String

    private enum Block {
        case paragraph(String)
        case heading(String)
        case bullet(String, level: Int)
        case code(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil

        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let finished = code {
                    result.append(.code(finished.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") {
                flush()
                let title = trimmed.drop(while: { $0 == "#" })
                result.append(.heading(title.trimmingCharacters(in: .whitespaces)))
            } else if ["- ", "* ", "• "].contains(where: { trimmed.hasPrefix($0) }) {
                flush()
                let spaces = line.prefix(while: { $0 == " " }).count
                let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                result.append(.bullet(content, level: min(spaces / 2, 3)))
            } else {
                paragraph.append(trimmed)
            }
        }

        if let unfinished = code {
            result.append(.code(unfinished.joined(separator: "\n")))
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: 13.5))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            Text(inlineMarkdown(content))
                .lineSpacing(4)
                .foregroundStyle(OLTheme.textBody)

        case .heading(let content):
            Text(inlineMarkdown(content))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OLTheme.textPrimary)

        case .bullet(let content, let level):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OLTheme.green)
                Text(inlineMarkdown(content))
                    .lineSpacing(3)
                    .foregroundStyle(OLTheme.textSecondary)
            }
            .padding(.leading, CGFloat(level) * 18)

        case .code(let content):
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(OLTheme.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .olPanel(radius: 10, fill: OLTheme.surfaceLow, border: OLTheme.borderSoft)
        }
    }
}

// MARK: - 3. Math & Graphing section
struct MathGraphingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 34))
                .foregroundStyle(OLTheme.accentSoft)
            OLEyebrow("Coming soon", color: OLTheme.textMuted)
            Text("Math & Equation Grapher")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(OLTheme.textPrimary)
            Text("Test slope-intercept forms, intercepts, and linear equations interactively.")
                .foregroundStyle(OLTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(36)
        .olPanel(radius: 20)
        .olRiseIn()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
