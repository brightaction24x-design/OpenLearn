
//
//  Flashcard.swift
//  OpenLearn
//
//  Created by Abdullah  on 23/11/2026.
//


import SwiftUI
import Combine
import PDFKit
import UniformTypeIdentifiers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Models
struct Flashcard: Identifiable, Codable {
    var id = UUID()
    var front: String
    var back: String
    var known = false
}

struct StudySet: Identifiable, Codable {
    var id = UUID()
    var title: String
    var material = ""
    var cards: [Flashcard] = []
    var updatedAt = Date()
}

private struct GeneratedCard: Decodable {
    let front: String
    let back: String
}

// MARK: - Store (all study sets, saved to disk)
@MainActor
final class StudyStore: ObservableObject {
    static let shared = StudyStore()

    @Published var sets: [StudySet] = []
    @Published var generatingIDs: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenLearn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("studysets.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([StudySet].self, from: data) {
            sets = saved
        }
    }

    // MARK: Lookups
    func studySet(_ id: UUID) -> StudySet? {
        sets.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        sets.firstIndex { $0.id == id }
    }

    // MARK: Sets
    @discardableResult
    func createSet(title: String) -> UUID {
        let item = StudySet(title: title)
        sets.insert(item, at: 0)
        save()
        return item.id
    }

    func deleteSet(_ id: UUID) {
        sets.removeAll { $0.id == id }
        generatingIDs.remove(id)
        errors[id] = nil
        save()
    }

    func rename(_ id: UUID, _ title: String) {
        guard let i = index(of: id) else { return }
        sets[i].title = title
        scheduleSave()
    }

    func setMaterial(_ id: UUID, _ text: String) {
        guard let i = index(of: id) else { return }
        sets[i].material = text
        sets[i].updatedAt = Date()
        scheduleSave()
    }

    // MARK: Cards
    func addCard(to setID: UUID, front: String, back: String) {
        guard let i = index(of: setID) else { return }
        sets[i].cards.append(Flashcard(front: front.trimmed, back: back.trimmed))
        sets[i].updatedAt = Date()
        save()
    }

    func deleteCard(_ cardID: UUID, from setID: UUID) {
        guard let i = index(of: setID) else { return }
        sets[i].cards.removeAll { $0.id == cardID }
        save()
    }

    func setKnown(_ cardID: UUID, _ known: Bool, in setID: UUID) {
        guard let i = index(of: setID),
              let j = sets[i].cards.firstIndex(where: { $0.id == cardID }) else { return }
        sets[i].cards[j].known = known
        save()
    }

    /// A binding to a card's front or back text, for editing in place.
    func binding(setID: UUID, cardID: UUID, keyPath: WritableKeyPath<Flashcard, String>) -> Binding<String> {
        Binding(
            get: {
                self.studySet(setID)?.cards.first(where: { $0.id == cardID })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let i = self.index(of: setID),
                      let j = self.sets[i].cards.firstIndex(where: { $0.id == cardID }) else { return }
                self.sets[i].cards[j][keyPath: keyPath] = newValue
                self.scheduleSave()
            }
        )
    }

    // MARK: AI generation
    func generateCards(for id: UUID, count: Int) {
        guard let item = studySet(id), !generatingIDs.contains(id) else { return }
        let material = item.material.trimmed
        guard !material.isEmpty else { return }

        errors[id] = nil
        generatingIDs.insert(id)

        let key = KeychainStore.get("apiKey")
        let prompt = """
        Create exactly \(count) flashcards from the study material below. Each card should test one clear idea, with a short front (a question or term) and a clear, concise back (the answer or definition).

        Reply with ONLY a JSON array and nothing else: no markdown, no code fences, no commentary. Use exactly this format:
        [{"front": "question or term", "back": "answer or definition"}]

        STUDY MATERIAL:
        \(String(material.prefix(30000)))
        """

        Task {
            do {
                let reply = try await GeminiService(apiKey: key)
                    .send(history: [GeminiMessage(role: "user", text: prompt)])

                if let cards = Self.parseCards(reply), !cards.isEmpty {
                    if let i = index(of: id) {
                        sets[i].cards.append(contentsOf: cards)
                        sets[i].updatedAt = Date()
                    }
                    save()
                } else {
                    errors[id] = "The AI's answer wasn't in the expected format. Try generating again."
                }
            } catch {
                errors[id] = error.localizedDescription
            }
            generatingIDs.remove(id)
        }
    }

    private static func parseCards(_ text: String) -> [Flashcard]? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else { return nil }

        let jsonString = String(text[start...end])
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([GeneratedCard].self, from: data) else { return nil }

        return decoded
            .filter { !$0.front.trimmed.isEmpty && !$0.back.trimmed.isEmpty }
            .map { Flashcard(front: $0.front.trimmed, back: $0.back.trimmed) }
    }

    // MARK: Saving
    func save() {
        if let data = try? JSONEncoder().encode(sets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Waits a moment after typing stops, so we don't write to disk on every keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { save() }
        }
    }
}

// MARK: - 2. Study Sets Section (list of sets)
struct StudySetsView: View {
    @ObservedObject private var store = StudyStore.shared
    @State private var selectedSetID: UUID?
    @State private var showNewSet = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if let id = selectedSetID, store.studySet(id) != nil {
                StudySetDetailView(store: store, setID: id) {
                    selectedSetID = nil
                }
            } else {
                setList
            }
        }
        .navigationTitle("Study Sets")
        .sheet(isPresented: $showNewSet) {
            newSetSheet
        }
    }

    private var setList: some View {
        ScrollView {
            if store.sets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 40))
                        .foregroundColor(.indigo)
                    Text("Your Study Sets")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Create a set, add your notes as material, and let the AI turn them into flashcards.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create your first set") {
                        openNewSet()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(store.sets.sorted { $0.updatedAt > $1.updatedAt }) { item in
                        Button {
                            selectedSetID = item.id
                        } label: {
                            setCard(item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete set", role: .destructive) {
                                store.deleteSet(item.id)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    openNewSet()
                } label: {
                    Label("New set", systemImage: "plus")
                }
                .help("Create a new study set")
            }
        }
    }

    private func setCard(_ item: StudySet) -> some View {
        let known = item.cards.filter { $0.known }.count
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundColor(.indigo)
            Text(item.title.isEmpty ? "Untitled set" : item.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(item.cards.count) cards · \(known) known")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(14)
    }

    private var newSetSheet: some View {
        VStack(spacing: 16) {
            Text("New study set")
                .font(.headline)

            TextField("e.g. Calculus Chapter 3", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createSet() }

            HStack {
                Button("Cancel") {
                    showNewSet = false
                }
                .buttonStyle(.bordered)

                Button("Create") {
                    createSet()
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(newTitle.trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func openNewSet() {
        newTitle = ""
        showNewSet = true
    }

    private func createSet() {
        let title = newTitle.trimmed
        guard !title.isEmpty else { return }
        selectedSetID = store.createSet(title: title)
        showNewSet = false
    }
}

// MARK: - Set detail (Material / Cards / Study)
struct StudySetDetailView: View {
    @ObservedObject var store: StudyStore
    let setID: UUID
    var onBack: () -> Void

    enum Mode: String, CaseIterable {
        case material = "Material"
        case cards = "Cards"
        case study = "Study"
    }

    @State private var mode: Mode = .material

    private var titleBinding: Binding<String> {
        Binding(
            get: { store.studySet(setID)?.title ?? "" },
            set: { store.rename(setID, $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    onBack()
                } label: {
                    Label("Sets", systemImage: "chevron.left")
                }

                TextField("Set title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))

                Spacer()

                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            .padding()

            Divider()

            switch mode {
            case .material:
                MaterialTab(store: store, setID: setID)
            case .cards:
                CardsTab(store: store, setID: setID)
            case .study:
                StudyTab(store: store, setID: setID)
            }
        }
        .navigationTitle(store.studySet(setID)?.title ?? "Study Set")
    }
}

// MARK: - Material tab
struct MaterialTab: View {
    @ObservedObject var store: StudyStore
    let setID: UUID

    @State private var cardCount = 10
    @State private var importError = ""

    private var material: String { store.studySet(setID)?.material ?? "" }
    private var cardTotal: Int { store.studySet(setID)?.cards.count ?? 0 }
    private var isGenerating: Bool { store.generatingIDs.contains(setID) }
    private var hasMaterial: Bool { !material.trimmed.isEmpty }

    private var materialBinding: Binding<String> {
        Binding(
            get: { store.studySet(setID)?.material ?? "" },
            set: { store.setMaterial(setID, $0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste your notes or import a file. The AI makes flashcards from this material.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                TextEditor(text: materialBinding)
                    .font(.body)
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                HStack {
                    Button {
                        importFile()
                    } label: {
                        Label("Import .txt / .md / .pdf", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("\(material.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !importError.isEmpty {
                    Text(importError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                HStack(spacing: 12) {
                    Stepper("Cards to make: \(cardCount)", value: $cardCount, in: 5...30, step: 5)

                    Spacer()

                    Button {
                        store.generateCards(for: setID, count: cardCount)
                    } label: {
                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Generating...")
                            }
                        } else {
                            Label("Generate flashcards", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(!hasMaterial || isGenerating)
                }

                if let error = store.errors[setID] {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if cardTotal > 0 {
                    Text("This set has \(cardTotal) cards. Generating again adds more cards to them.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }

    private func importFile() {
        importError = ""

        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .pdf]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var text = ""
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string ?? ""
        } else {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        if text.trimmed.isEmpty {
            importError = "Couldn't read text from that file. If it's a scanned PDF it has no text to read. Otherwise, in Xcode go to Signing & Capabilities → App Sandbox → File Access and set User Selected File to Read Only."
            return
        }

        let existing = material
        store.setMaterial(setID, existing.isEmpty ? text : existing + "\n\n" + text)
    }
}

// MARK: - Cards tab
struct CardsTab: View {
    @ObservedObject var store: StudyStore
    let setID: UUID

    @State private var newFront = ""
    @State private var newBack = ""

    private var cards: [Flashcard] { store.studySet(setID)?.cards ?? [] }

    var body: some View {
        List {
            Section("Add a card") {
                TextField("Front (question or term)", text: $newFront)
                TextField("Back (answer or definition)", text: $newBack)
                Button("Add card") {
                    store.addCard(to: setID, front: newFront, back: newBack)
                    newFront = ""
                    newBack = ""
                }
                .disabled(newFront.trimmed.isEmpty || newBack.trimmed.isEmpty)
            }

            Section("\(cards.count) cards") {
                if cards.isEmpty {
                    Text("No cards yet. Add one above, or generate them from your material.")
                        .foregroundColor(.secondary)
                }

                ForEach(cards) { card in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Front",
                                text: store.binding(setID: setID, cardID: card.id, keyPath: \.front),
                                axis: .vertical
                            )
                            .font(.headline)

                            TextField(
                                "Back",
                                text: store.binding(setID: setID, cardID: card.id, keyPath: \.back),
                                axis: .vertical
                            )
                            .foregroundColor(.secondary)
                        }

                        Spacer()

                        if card.known {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }

                        Button(role: .destructive) {
                            store.deleteCard(card.id, from: setID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Study tab
struct StudyTab: View {
    @ObservedObject var store: StudyStore
    let setID: UUID

    @State private var order: [UUID] = []
    @State private var index = 0
    @State private var showBack = false
    @State private var onlyLearning = false

    private var cards: [Flashcard] { store.studySet(setID)?.cards ?? [] }
    private var knownCount: Int { cards.filter { $0.known }.count }

    private var currentCard: Flashcard? {
        guard index < order.count else { return nil }
        return cards.first { $0.id == order[index] }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                if !order.isEmpty {
                    Text("Card \(min(index + 1, order.count)) of \(order.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("Only cards I'm still learning", isOn: $onlyLearning)
                    .toggleStyle(.checkbox)

                Button {
                    rebuild(shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .disabled(cards.isEmpty)
            }

            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(knownCount), total: Double(max(cards.count, 1)))
                        .tint(.green)
                    Text("\(knownCount) of \(cards.count) known")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear { rebuild(shuffle: false) }
        .onChange(of: onlyLearning) { rebuild(shuffle: false) }
    }

    @ViewBuilder
    private var content: some View {
        if cards.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 36))
                    .foregroundColor(.indigo)
                Text("No cards yet")
                    .font(.headline)
                Text("Add cards in the Cards tab, or generate them from your material.")
                    .foregroundColor(.secondary)
            }
        } else if order.isEmpty {
            VStack(spacing: 12) {
                Text("Nothing left to review")
                    .font(.headline)
                Text("You've marked every card as known.")
                    .foregroundColor(.secondary)
                Button("Study all cards") {
                    onlyLearning = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        } else if let card = currentCard {
            VStack(spacing: 20) {
                Button {
                    showBack.toggle()
                } label: {
                    VStack(spacing: 12) {
                        Text(showBack ? "ANSWER" : "QUESTION")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        Text(showBack ? card.back : card.front)
                            .font(.title2)
                            .multilineTextAlignment(.center)

                        Text("Click the card or press Space to flip")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: 640, minHeight: 260)
                    .padding(32)
                    .background(showBack ? Color.indigo.opacity(0.18) : Color.secondary.opacity(0.12))
                    .cornerRadius(20)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                HStack(spacing: 12) {
                    Button("Previous") {
                        previous()
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)

                    Button("Still learning") {
                        mark(known: false)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button("Got it") {
                        mark(known: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button("Skip") {
                        next()
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text("Round finished")
                    .font(.title2.weight(.bold))
                Text("You've marked \(knownCount) of \(cards.count) cards as known.")
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("Study again") {
                        rebuild(shuffle: false)
                    }
                    .buttonStyle(.bordered)

                    Button("Review what I missed") {
                        if onlyLearning {
                            rebuild(shuffle: true)
                        } else {
                            onlyLearning = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(knownCount == cards.count)
                }
            }
        }
    }

    // MARK: Actions
    private func rebuild(shuffle: Bool) {
        var ids = cards.filter { !onlyLearning || !$0.known }.map { $0.id }
        if shuffle { ids.shuffle() }
        order = ids
        index = 0
        showBack = false
    }

    private func mark(known: Bool) {
        guard let card = currentCard else { return }
        store.setKnown(card.id, known, in: setID)
        next()
    }

    private func next() {
        showBack = false
        index += 1
    }

    private func previous() {
        guard index > 0 else { return }
        showBack = false
        index -= 1
    }
}
