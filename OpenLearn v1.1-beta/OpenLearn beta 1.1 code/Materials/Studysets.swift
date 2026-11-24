import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Date helpers (dates are stored as "YYYY-MM-DD")
enum DateKey {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .current
        f.dateFormat = "EEE"
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
    static var today: String { string(from: Date()) }

    static func weekday(_ string: String) -> String {
        guard let d = date(from: string) else { return "" }
        return weekdayFormatter.string(from: d)
    }

    static func days(from a: String, to b: String) -> Int? {
        guard let d1 = date(from: a), let d2 = date(from: b) else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: d1),
            to: calendar.startOfDay(for: d2)
        ).day
    }

    static func countdown(to string: String) -> String {
        guard let n = days(from: today, to: string) else { return "" }
        if n < 0 { return "passed" }
        if n == 0 { return "today" }
        if n == 1 { return "tomorrow" }
        return "in \(n) days"
    }
}

// MARK: - Models
struct Flashcard: Identifiable, Codable {
    var id = UUID()
    var front: String
    var back: String
    var known = false
}

struct ExamEvent: Identifiable, Codable {
    var id = UUID()
    var name: String
    var date: String          // YYYY-MM-DD
    var topics = ""
}

struct PlanItem: Identifiable, Codable {
    var id = UUID()
    var date: String          // YYYY-MM-DD
    var title: String
    var details = ""
    var done = false
}

struct StudySet: Identifiable, Codable {
    var id = UUID()
    var title: String
    var material = ""
    var files: [MaterialFile] = []
    var syllabusFiles: [MaterialFile] = []
    var exams: [ExamEvent] = []
    var plan: [PlanItem] = []
    var hoursPerDay = 2
    var cards: [Flashcard] = []
    var updatedAt = Date()

    init(title: String) {
        self.title = title
    }

    // Lets sets saved by older versions of the app still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled set"
        material = try c.decodeIfPresent(String.self, forKey: .material) ?? ""
        files = try c.decodeIfPresent([MaterialFile].self, forKey: .files) ?? []
        syllabusFiles = try c.decodeIfPresent([MaterialFile].self, forKey: .syllabusFiles) ?? []
        exams = try c.decodeIfPresent([ExamEvent].self, forKey: .exams) ?? []
        plan = try c.decodeIfPresent([PlanItem].self, forKey: .plan) ?? []
        hoursPerDay = try c.decodeIfPresent(Int.self, forKey: .hoursPerDay) ?? 2
        cards = try c.decodeIfPresent([Flashcard].self, forKey: .cards) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

private struct GeneratedCard: Decodable {
    let front: String
    let back: String
}

private struct GeneratedExam: Decodable {
    let name: String
    let date: String
    let topics: String?
}

private struct GeneratedPlanItem: Decodable {
    let date: String
    let title: String
    let details: String?
}

// MARK: - Errors
enum StudyError: LocalizedError {
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .badFormat(let snippet):
            let shown = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The AI's answer wasn't in the expected format, even after a second try. It replied: \"\(shown)\""
        }
    }
}

// MARK: - Store (all study sets, saved to disk)
@MainActor
final class StudyStore: ObservableObject {
    static let shared = StudyStore()

    enum Activity {
        case cards
        case syllabus
        case plan
    }

    @Published var sets: [StudySet] = []
    @Published var busy: [UUID: Activity] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var notices: [UUID: String] = [:]

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
        if let item = studySet(id) {
            (item.files + item.syllabusFiles).forEach { FileImporter.deleteStoredFile(for: $0) }
        }
        sets.removeAll { $0.id == id }
        busy[id] = nil
        errors[id] = nil
        notices[id] = nil
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

    func setHours(_ hours: Int, for id: UUID) {
        guard let i = index(of: id) else { return }
        sets[i].hoursPerDay = hours
        scheduleSave()
    }

    // MARK: Files
    func importFiles(_ urls: [URL], into setID: UUID, syllabus: Bool) {
        guard index(of: setID) != nil else { return }
        var problems: [String] = []

        for url in urls {
            do {
                let file = try FileImporter.importFile(at: url)
                guard let i = index(of: setID) else { return }
                if syllabus {
                    sets[i].syllabusFiles.append(file)
                } else {
                    sets[i].files.append(file)
                }
                sets[i].updatedAt = Date()
            } catch {
                problems.append(error.localizedDescription)
            }
        }

        errors[setID] = problems.isEmpty ? nil : problems.joined(separator: "\n")
        save()
    }

    func removeFile(_ fileID: UUID, from setID: UUID, syllabus: Bool) {
        guard let i = index(of: setID) else { return }
        if syllabus {
            if let file = sets[i].syllabusFiles.first(where: { $0.id == fileID }) {
                FileImporter.deleteStoredFile(for: file)
            }
            sets[i].syllabusFiles.removeAll { $0.id == fileID }
        } else {
            if let file = sets[i].files.first(where: { $0.id == fileID }) {
                FileImporter.deleteStoredFile(for: file)
            }
            sets[i].files.removeAll { $0.id == fileID }
        }
        save()
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

    // MARK: Exams
    func addExam(to setID: UUID, name: String, date: Date) {
        guard let i = index(of: setID) else { return }
        sets[i].exams.append(ExamEvent(name: name.trimmed, date: DateKey.string(from: date)))
        save()
    }

    func deleteExam(_ examID: UUID, from setID: UUID) {
        guard let i = index(of: setID) else { return }
        sets[i].exams.removeAll { $0.id == examID }
        save()
    }

    func updateExam(_ examID: UUID, in setID: UUID, _ change: (inout ExamEvent) -> Void) {
        guard let i = index(of: setID),
              let j = sets[i].exams.firstIndex(where: { $0.id == examID }) else { return }
        change(&sets[i].exams[j])
        scheduleSave()
    }

    // MARK: Plan
    func togglePlanItem(_ itemID: UUID, in setID: UUID) {
        guard let i = index(of: setID),
              let j = sets[i].plan.firstIndex(where: { $0.id == itemID }) else { return }
        sets[i].plan[j].done.toggle()
        save()
    }

    // MARK: AI context
    private struct Gathered {
        var text = ""
        var attachments: [GeminiAttachment] = []
        var names: [String] = []
        var skipped: [String] = []
    }

    private struct Context {
        var text = ""
        var attachments: [GeminiAttachment] = []
        var skipped: [String] = []
    }

    /// Splits files into text (read on the Mac) and attachments (images / PDFs sent to the AI).
    private func gather(_ files: [MaterialFile], budget: inout Int) -> Gathered {
        var result = Gathered()

        for file in files {
            switch file.kind {
            case .text:
                if file.text.trimmed.isEmpty {
                    result.skipped.append(file.name)
                } else {
                    result.text += "--- \(file.name) ---\n\(file.text)\n\n"
                }

            case .image:
                if let data = FileImporter.fileData(for: file), data.count <= budget {
                    result.attachments.append(GeminiAttachment(mimeType: "image/jpeg", data: data))
                    result.names.append(file.name)
                    budget -= data.count
                } else {
                    result.skipped.append(file.name)
                }

            case .pdf:
                if let data = FileImporter.fileData(for: file), data.count <= budget {
                    result.attachments.append(GeminiAttachment(mimeType: "application/pdf", data: data))
                    result.names.append(file.name)
                    budget -= data.count
                } else if !file.text.trimmed.isEmpty {
                    // Too big to attach: fall back to the text inside it
                    result.text += "--- \(file.name) ---\n\(file.text)\n\n"
                } else {
                    result.skipped.append(file.name)
                }
            }
        }
        return result
    }

    private func buildContext(for item: StudySet, includeSyllabus: Bool, includeMaterial: Bool) -> Context {
        var budget = 14_000_000      // stays under Google's request size limit
        var context = Context()
        var sections: [String] = []
        var attachedNames: [String] = []

        if includeSyllabus {
            let g = gather(item.syllabusFiles, budget: &budget)
            context.attachments += g.attachments
            context.skipped += g.skipped
            attachedNames += g.names.map { "\($0) (syllabus)" }
            if !g.text.isEmpty { sections.append("SYLLABUS TEXT:\n\(g.text)") }
        }

        if includeMaterial {
            if !item.material.trimmed.isEmpty {
                sections.append("STUDENT NOTES:\n\(item.material)")
            }
            let g = gather(item.files, budget: &budget)
            context.attachments += g.attachments
            context.skipped += g.skipped
            attachedNames += g.names
            if !g.text.isEmpty { sections.append("STUDY MATERIAL FILES:\n\(g.text)") }
        }

        var text = sections.joined(separator: "\n\n")
        if !attachedNames.isEmpty {
            text = "ATTACHED FILES (in this order): \(attachedNames.joined(separator: ", "))\n\n" + text
        }
        context.text = String(text.prefix(45_000))
        return context
    }

    private func skippedNotice(_ skipped: [String]) -> String? {
        skipped.isEmpty ? nil : "Skipped (too large or unreadable): \(skipped.joined(separator: ", "))"
    }

    // MARK: AI helpers (JSON answers)
    /// Asks the AI and makes sure the answer is a JSON list. Tries twice,
    /// then shows what the AI actually said.
    private func ask(_ prompt: String, attachments: [GeminiAttachment]) async throws -> String {
        let service = GeminiService(apiKey: KeychainStore.get("apiKey"))
        var lastReply = ""

        for _ in 0..<2 {
            let reply = try await service.send(
                history: [GeminiMessage(role: "user", text: prompt, attachments: attachments)],
                longTask: true
            )
            lastReply = reply
            if Self.extractJSONArray(reply) != nil { return reply }
        }
        throw StudyError.badFormat(String(lastReply.prefix(300)))
    }

    /// Pulls a JSON list out of the AI's answer, even with extra text around it,
    /// and repairs answers that were cut off before the closing bracket.
    private static func extractJSONArray(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }

        var candidates: [String] = []
        if let end = text.lastIndex(of: "]"), start < end {
            candidates.append(String(text[start...end]))
        }
        if let lastBrace = text.lastIndex(of: "}"), start < lastBrace {
            candidates.append(String(text[start...lastBrace]) + "]")
        }

        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) is [Any] {
                return candidate
            }
        }
        return nil
    }

    private static func parseArray<T: Decodable>(_ text: String, as type: T.Type) -> [T]? {
        guard let json = extractJSONArray(text),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }

    // MARK: AI: flashcards
    func generateCards(for id: UUID, count: Int) {
        guard let item = studySet(id), busy[id] == nil else { return }

        let context = buildContext(for: item, includeSyllabus: false, includeMaterial: true)
        guard !context.text.trimmed.isEmpty || !context.attachments.isEmpty else {
            errors[id] = "Add some notes or files first."
            return
        }

        errors[id] = nil
        notices[id] = skippedNotice(context.skipped)
        busy[id] = .cards

        let prompt = """
        Create exactly \(count) flashcards from the study material below and any attached files (read images and PDFs carefully, including diagrams and handwriting). Each card should test one clear idea, with a short front (a question or term) and a clear, concise back (the answer or definition). If the material only contains questions without answers, write the correct answers yourself.

        Reply with ONLY a JSON array and nothing else: no markdown, no code fences, no commentary. Use exactly this format:
        [{"front": "question or term", "back": "answer or definition"}]

        \(context.text)
        """

        Task {
            do {
                let reply = try await ask(prompt, attachments: context.attachments)
                if let generated = Self.parseArray(reply, as: GeneratedCard.self) {
                    let cards = generated
                        .filter { !$0.front.trimmed.isEmpty && !$0.back.trimmed.isEmpty }
                        .map { Flashcard(front: $0.front.trimmed, back: $0.back.trimmed) }

                    if cards.isEmpty {
                        errors[id] = "The AI didn't return any usable cards. Try again."
                    } else if let i = index(of: id) {
                        sets[i].cards.append(contentsOf: cards)
                        sets[i].updatedAt = Date()
                        save()
                    }
                } else {
                    errors[id] = "The AI's answer used different field names than expected. Try generating again, or pick a different model in the chat toolbar."
                }
            } catch {
                errors[id] = error.localizedDescription
            }
            busy[id] = nil
        }
    }

    // MARK: AI: read exam dates from the syllabus
    func extractExams(for id: UUID) {
        guard let item = studySet(id), busy[id] == nil else { return }

        let context = buildContext(for: item, includeSyllabus: true, includeMaterial: false)
        guard !context.text.trimmed.isEmpty || !context.attachments.isEmpty else {
            errors[id] = "Add your syllabus first."
            return
        }

        errors[id] = nil
        notices[id] = skippedNotice(context.skipped)
        busy[id] = .syllabus

        let prompt = """
        Today's date is \(DateKey.today). Read the attached syllabus or course documents and list every exam, test, quiz, midterm, final and other major graded assessment that has a date.

        Reply with ONLY a JSON array and nothing else: no markdown, no code fences. Use exactly this format:
        [{"name": "Midterm 1", "date": "YYYY-MM-DD", "topics": "short list of topics covered, or an empty string"}]

        Rules:
        - "date" must be YYYY-MM-DD.
        - If the year is missing, use the next occurrence of that date on or after today.
        - Skip anything without a date.
        - If you find nothing, reply with [].

        \(context.text)
        """

        Task {
            do {
                let reply = try await ask(prompt, attachments: context.attachments)
                if let found = Self.parseArray(reply, as: GeneratedExam.self) {
                    var added = 0
                    if let i = index(of: id) {
                        for exam in found {
                            let name = exam.name.trimmed
                            guard !name.isEmpty, DateKey.date(from: exam.date) != nil else { continue }
                            let duplicate = sets[i].exams.contains { $0.name == name && $0.date == exam.date }
                            if duplicate { continue }
                            sets[i].exams.append(ExamEvent(name: name, date: exam.date, topics: (exam.topics ?? "").trimmed))
                            added += 1
                        }
                        save()
                    }
                    if added > 0 {
                        notices[id] = "Found \(added) exam date\(added == 1 ? "" : "s"). Check them below and fix anything that's wrong."
                    } else {
                        notices[id] = "No new exam dates found. Add them by hand below."
                    }
                } else {
                    errors[id] = "The AI's answer used different field names than expected. Try again, or pick a different model in the chat toolbar."
                }
            } catch {
                errors[id] = error.localizedDescription
            }
            busy[id] = nil
        }
    }

    // MARK: AI: build the study plan
    func buildPlan(for id: UUID) {
        guard let item = studySet(id), busy[id] == nil else { return }

        let today = DateKey.today
        let upcoming = item.exams.filter { $0.date >= today }.sorted { $0.date < $1.date }
        guard let lastExam = upcoming.last else {
            errors[id] = "Add at least one upcoming exam date first."
            return
        }

        let context = buildContext(for: item, includeSyllabus: true, includeMaterial: true)

        errors[id] = nil
        notices[id] = skippedNotice(context.skipped)
        busy[id] = .plan

        let examLines = upcoming.map { exam -> String in
            let topics = exam.topics.trimmed.isEmpty ? "" : " (topics: \(exam.topics.trimmed))"
            return "- \(exam.name): \(exam.date)\(topics)"
        }.joined(separator: "\n")

        let daysLeft = DateKey.days(from: today, to: lastExam.date) ?? 0

        let prompt = """
        You are a study coach. Today's date is \(today). The student's last exam is on \(lastExam.date), which is \(daysLeft) days away.

        Exams:
        \(examLines)

        The student can study about \(item.hoursPerDay) hours per day.

        Using the syllabus and study material below (and any attached files), create a day-by-day study plan from today until the last exam.

        Rules:
        - Every date must be between \(today) and \(lastExam.date), written as YYYY-MM-DD.
        - Cover every topic from the syllabus and material. Put harder or bigger topics earlier, and schedule spaced review before each exam.
        - On the day before each exam, do revision and practice questions. On an exam day, only light review.
        - One entry per study day. You may skip rest days. If the last exam is more than 30 days away, use one entry per day for the first 14 days and one entry per week after that.
        - Each entry has a short "title" and "details" (1 to 3 sentences saying exactly what to study or practice, with a time estimate that fits \(item.hoursPerDay) hours per day).
        - No more than 60 entries.

        Reply with ONLY a JSON array and nothing else: no markdown, no code fences. Use exactly this format:
        [{"date": "YYYY-MM-DD", "title": "short title", "details": "what to do"}]

        \(context.text)
        """

        Task {
            do {
                let reply = try await ask(prompt, attachments: context.attachments)
                if let generated = Self.parseArray(reply, as: GeneratedPlanItem.self) {
                    let items = generated.compactMap { g -> PlanItem? in
                        guard DateKey.date(from: g.date) != nil,
                              g.date >= today,
                              g.date <= lastExam.date,
                              !g.title.trimmed.isEmpty else { return nil }
                        return PlanItem(date: g.date, title: g.title.trimmed, details: (g.details ?? "").trimmed)
                    }

                    let sorted = items.enumerated()
                        .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
                        .map { $0.element }

                    if sorted.isEmpty {
                        errors[id] = "The AI didn't return a usable plan. Try again."
                    } else if let i = index(of: id) {
                        sets[i].plan = sorted
                        sets[i].updatedAt = Date()
                        save()
                    }
                } else {
                    errors[id] = "The AI's answer used different field names than expected. Try again, or pick a different model in the chat toolbar."
                }
            } catch {
                errors[id] = error.localizedDescription
            }
            busy[id] = nil
        }
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

// MARK: - Small shared views
private enum FilePicker {
    static func pick(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        var types: [UTType] = [.pdf, .image, .plainText, .rtf]
        for ext in ["docx", "doc", "pptx", "xlsx", "md", "csv", "pages", "key", "numbers"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types

        return panel.runModal() == .OK ? panel.urls : []
    }
}

private struct FileRows: View {
    let files: [MaterialFile]
    var onRemove: (UUID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(files) { file in
                HStack(spacing: 10) {
                    Image(systemName: file.icon)
                        .foregroundColor(.indigo)
                    Text(file.name)
                        .lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        onRemove(file.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this file")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}

private struct ActionLabel: View {
    let title: String
    let busyTitle: String
    let icon: String
    let isBusy: Bool

    var body: some View {
        if isBusy {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(busyTitle)
            }
        } else {
            Label(title, systemImage: icon)
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
                    Text("Create a set, add notes, photos, PDFs or slides, and let the AI make flashcards and a study plan.")
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
        let nextExam = item.exams.filter { $0.date >= DateKey.today }.sorted { $0.date < $1.date }.first

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
            if let exam = nextExam {
                Text("\(exam.name) \(DateKey.countdown(to: exam.date))")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
            }
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

// MARK: - Set detail (Material / Cards / Study / Plan)
struct StudySetDetailView: View {
    @ObservedObject var store: StudyStore
    let setID: UUID
    var onBack: () -> Void

    enum Mode: String, CaseIterable {
        case material = "Material"
        case cards = "Cards"
        case study = "Study"
        case plan = "Plan"
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
                .frame(width: 340)
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
            case .plan:
                PlanTab(store: store, setID: setID)
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

    private var item: StudySet? { store.studySet(setID) }
    private var files: [MaterialFile] { item?.files ?? [] }
    private var material: String { item?.material ?? "" }
    private var cardTotal: Int { item?.cards.count ?? 0 }
    private var isGenerating: Bool { store.busy[setID] == .cards }
    private var isBusy: Bool { store.busy[setID] != nil }
    private var hasMaterial: Bool { !material.trimmed.isEmpty || !files.isEmpty }

    private var materialBinding: Binding<String> {
        Binding(
            get: { store.studySet(setID)?.material ?? "" },
            set: { store.setMaterial(setID, $0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Type or paste notes, and add files. The AI reads photos, PDFs, Word, PowerPoint and Excel files.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                TextEditor(text: materialBinding)
                    .font(.body)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                HStack {
                    Button {
                        let urls = FilePicker.pick(message: "Choose your study material")
                        if !urls.isEmpty {
                            store.importFiles(urls, into: setID, syllabus: false)
                        }
                    } label: {
                        Label("Add files (PDF, photos, Word, PowerPoint...)", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("\(material.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !files.isEmpty {
                    FileRows(files: files) { fileID in
                        store.removeFile(fileID, from: setID, syllabus: false)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Stepper("Cards to make: \(cardCount)", value: $cardCount, in: 5...30, step: 5)

                    Spacer()

                    Button {
                        store.generateCards(for: setID, count: cardCount)
                    } label: {
                        ActionLabel(
                            title: "Generate flashcards",
                            busyTitle: "Generating...",
                            icon: "sparkles",
                            isBusy: isGenerating
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(!hasMaterial || isBusy)
                }

                if let error = store.errors[setID] {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }

                if let notice = store.notices[setID] {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.secondary)
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

// MARK: - Plan tab (syllabus, exam dates, study plan)
struct PlanTab: View {
    @ObservedObject var store: StudyStore
    let setID: UUID

    @State private var newExamName = ""
    @State private var newExamDate = Date()

    private struct DayGroup: Identifiable {
        let date: String
        var items: [PlanItem]
        var id: String { date }
    }

    private var item: StudySet? { store.studySet(setID) }
    private var syllabusFiles: [MaterialFile] { item?.syllabusFiles ?? [] }
    private var exams: [ExamEvent] { (item?.exams ?? []).sorted { $0.date < $1.date } }
    private var plan: [PlanItem] { item?.plan ?? [] }
    private var activity: StudyStore.Activity? { store.busy[setID] }
    private var hasUpcomingExam: Bool { exams.contains { $0.date >= DateKey.today } }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { store.studySet(setID)?.hoursPerDay ?? 2 },
            set: { store.setHours($0, for: setID) }
        )
    }

    private var dayGroups: [DayGroup] {
        var groups: [DayGroup] = []
        for entry in plan {
            if let last = groups.last, last.date == entry.date {
                groups[groups.count - 1].items.append(entry)
            } else {
                groups.append(DayGroup(date: entry.date, items: [entry]))
            }
        }
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = store.errors[setID] {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
                if let notice = store.notices[setID] {
                    Text(notice)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                syllabusCard
                examsCard
                planCard
            }
            .padding()
        }
    }

    // MARK: Cards
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
    }

    private var syllabusCard: some View {
        card("Syllabus", icon: "doc.text.magnifyingglass") {
            Text("Upload your syllabus (PDF, photo, Word or PowerPoint). The AI finds your exam dates and topics.")
                .font(.callout)
                .foregroundColor(.secondary)

            if !syllabusFiles.isEmpty {
                FileRows(files: syllabusFiles) { fileID in
                    store.removeFile(fileID, from: setID, syllabus: true)
                }
            }

            HStack(spacing: 12) {
                Button {
                    let urls = FilePicker.pick(message: "Choose your syllabus")
                    if !urls.isEmpty {
                        store.importFiles(urls, into: setID, syllabus: true)
                    }
                } label: {
                    Label("Add syllabus files", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    store.extractExams(for: setID)
                } label: {
                    ActionLabel(
                        title: "Read exam dates",
                        busyTitle: "Reading...",
                        icon: "calendar.badge.clock",
                        isBusy: activity == .syllabus
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(syllabusFiles.isEmpty || activity != nil)
            }
        }
    }

    private var examsCard: some View {
        card("Exams", icon: "calendar") {
            if exams.isEmpty {
                Text("No exams yet. Read them from your syllabus above, or add one by hand.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            ForEach(exams) { exam in
                HStack(spacing: 12) {
                    TextField("Exam name", text: examNameBinding(exam.id))

                    DatePicker("", selection: examDateBinding(exam.id), displayedComponents: .date)
                        .labelsHidden()

                    Text(DateKey.countdown(to: exam.date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)

                    Button(role: .destructive) {
                        store.deleteExam(exam.id, from: setID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack(spacing: 12) {
                TextField("Add an exam (e.g. Midterm 1)", text: $newExamName)
                    .textFieldStyle(.roundedBorder)

                DatePicker("", selection: $newExamDate, displayedComponents: .date)
                    .labelsHidden()

                Button("Add") {
                    store.addExam(to: setID, name: newExamName, date: newExamDate)
                    newExamName = ""
                }
                .buttonStyle(.bordered)
                .disabled(newExamName.trimmed.isEmpty)
            }
        }
    }

    private var planCard: some View {
        card("Study plan", icon: "list.bullet.clipboard") {
            HStack(spacing: 12) {
                Stepper("Hours per day: \(hoursBinding.wrappedValue)", value: hoursBinding, in: 1...10)

                Spacer()

                Button {
                    store.buildPlan(for: setID)
                } label: {
                    ActionLabel(
                        title: plan.isEmpty ? "Build study plan" : "Rebuild plan",
                        busyTitle: "Planning...",
                        icon: "wand.and.stars",
                        isBusy: activity == .plan
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(!hasUpcomingExam || activity != nil)
            }

            if !hasUpcomingExam {
                Text("Add at least one upcoming exam date to build a plan.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !plan.isEmpty {
                Text("Rebuilding replaces the current plan and resets your checkmarks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if plan.isEmpty {
                Text("The plan uses your exam dates, syllabus, notes and files, and spreads the work from today until your last exam.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                let done = plan.filter { $0.done }.count

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(done), total: Double(max(plan.count, 1)))
                        .tint(.green)
                    Text("\(done) of \(plan.count) tasks done")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(dayGroups) { group in
                    dayView(group)
                }
            }
        }
    }

    private func dayView(_ group: DayGroup) -> some View {
        let isToday = group.date == DateKey.today
        let overdue = group.date < DateKey.today && group.items.contains { !$0.done }
        let examNames = exams.filter { $0.date == group.date }.map { $0.name }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(group.date) · \(DateKey.weekday(group.date))")
                    .font(.subheadline.weight(.semibold))
                if isToday { badge("Today", .indigo) }
                if overdue { badge("Overdue", .orange) }
                ForEach(examNames, id: \.self) { name in
                    badge("Exam: \(name)", .red)
                }
            }

            ForEach(group.items) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        store.togglePlanItem(entry.id, in: setID)
                    } label: {
                        Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(entry.done ? .green : .secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.headline)
                            .strikethrough(entry.done)
                        if !entry.details.isEmpty {
                            Text(entry.details)
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isToday ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.06))
        .cornerRadius(12)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    // MARK: Exam bindings
    private func examNameBinding(_ examID: UUID) -> Binding<String> {
        Binding(
            get: { store.studySet(setID)?.exams.first(where: { $0.id == examID })?.name ?? "" },
            set: { newValue in store.updateExam(examID, in: setID) { $0.name = newValue } }
        )
    }

    private func examDateBinding(_ examID: UUID) -> Binding<Date> {
        Binding(
            get: {
                let text = store.studySet(setID)?.exams.first(where: { $0.id == examID })?.date ?? ""
                return DateKey.date(from: text) ?? Date()
            },
            set: { newValue in
                store.updateExam(examID, in: setID) { $0.date = DateKey.string(from: newValue) }
            }
        )
    }
}
