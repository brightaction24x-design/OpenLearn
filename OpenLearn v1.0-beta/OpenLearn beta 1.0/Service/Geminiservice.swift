import Foundation

struct GeminiMessage {
    let role: String   // "user" or "model"
    let text: String
}

struct ModelOption {
    let id: String
    let label: String
}

enum GeminiError: LocalizedError {
    case badURL
    case invalidKey(String)
    case api(status: Int, message: String)
    case blocked(String)
    case emptyResponse
    case timedOut
    case allBusy

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid request URL."
        case .invalidKey(let message):
            return "Google rejected this key: \(message)"
        case .api(let status, let message):
            if status == 503 || status == 429 {
                return "Google's servers are busy right now (\(status)). Wait a minute and try again."
            }
            return "Gemini error \(status): \(message)"
        case .blocked(let reason):
            return "Response blocked (\(reason))."
        case .emptyResponse:
            return "The model returned an empty response."
        case .timedOut:
            return "Google took too long to answer. Send it again."
        case .allBusy:
            return "Every model is busy or unavailable right now. Wait a few minutes and try again."
        }
    }
}

struct GeminiService {
    let apiKey: String

    // MARK: - Model settings
    static let autoID = "auto"
    static let selectedModelKey = "selectedModel"
    static let lastWorkingKey = "lastWorkingModel"

    /// Models shown in the picker. Edit this list any time.
    static let models: [ModelOption] = [
        ModelOption(id: "gemini-3.5-flash-lite", label: "Gemini 3.5 Flash-Lite"),
        ModelOption(id: "gemini-3.1-flash-lite", label: "Gemini 3.1 Flash-Lite"),
        ModelOption(id: "gemini-3.5-flash", label: "Gemini 3.5 Flash"),
        ModelOption(id: "gemini-3.7-flash", label: "Gemini 3.7 Flash"),
        ModelOption(id: "gemini-3.8-flash", label: "Gemini 3.8 Flash")
    ]

    /// Order tried in Auto mode (lighter models first).
    static var autoOrder: [String] { models.map { $0.id } }

    // MARK: - Key verification
    /// Makes a free "list models" call to check that the key really works.
    static func verifyKey(_ key: String) async throws {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
        ) else { throw GeminiError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if status == 200 { return }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errorInfo = json?["error"] as? [String: Any]
        let message = (errorInfo?["message"] as? String) ?? "Unknown error"

        if status == 400 || status == 401 || status == 403 {
            throw GeminiError.invalidKey(message)
        }
        throw GeminiError.api(status: status, message: message)
    }

    // MARK: - Chat
    func send(history: [GeminiMessage]) async throws -> String {
        let choice = UserDefaults.standard.string(forKey: Self.selectedModelKey) ?? Self.autoID

        // Manual: use exactly the model the user picked
        if choice != Self.autoID {
            return try await sendWithRetries(model: choice, history: history, maxAttempts: 3, timeout: 90)
        }

        // Auto: try the last model that worked first, then the rest in order
        var order = Self.autoOrder
        if let last = UserDefaults.standard.string(forKey: Self.lastWorkingKey),
           let i = order.firstIndex(of: last) {
            order.remove(at: i)
            order.insert(last, at: 0)
        }

        var lastError: GeminiError = .allBusy
        for model in order {
            do {
                let text = try await sendWithRetries(model: model, history: history, maxAttempts: 1, timeout: 40)
                UserDefaults.standard.set(model, forKey: Self.lastWorkingKey)
                return text
            } catch let error as GeminiError {
                switch error {
                case .api(let status, _) where [404, 429, 500, 503, 504].contains(status):
                    lastError = error
                    continue          // try the next model
                case .timedOut:
                    lastError = error
                    continue          // try the next model
                default:
                    throw error       // bad key, blocked prompt, etc.: stop here
                }
            }
        }
        _ = lastError
        throw GeminiError.allBusy
    }

    /// Retries when Google is busy (429, 500, 503, 504) or the request times out.
    private func sendWithRetries(model: String, history: [GeminiMessage], maxAttempts: Int, timeout: TimeInterval) async throws -> String {
        let retryableStatuses: Set<Int> = [429, 500, 503, 504]
        var attempt = 0

        while true {
            attempt += 1
            do {
                return try await sendOnce(model: model, history: history, timeout: timeout)
            } catch GeminiError.api(let status, _) where retryableStatuses.contains(status) && attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            } catch GeminiError.timedOut where attempt < maxAttempts {
                // try again
            }
        }
    }

    private func sendOnce(model: String, history: [GeminiMessage], timeout: TimeInterval) async throws -> String {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else { throw GeminiError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let contents: [[String: Any]] = history.map {
            ["role": $0.role, "parts": [["text": $0.text]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": contents])

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiError.timedOut
        }

        let data = result.0
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard status == 200 else {
            let errorInfo = json?["error"] as? [String: Any]
            let message = (errorInfo?["message"] as? String) ?? "Unknown error"
            if status == 400 || status == 401 || status == 403 {
                throw GeminiError.invalidKey(message)
            }
            throw GeminiError.api(status: status, message: message)
        }

        if let feedback = json?["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String {
            throw GeminiError.blocked(reason)
        }

        guard let candidates = json?["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            throw GeminiError.emptyResponse
        }

        let content = first["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        let text = (parts ?? []).compactMap { $0["text"] as? String }.joined()

        if !text.isEmpty { return text }

        if let reason = first["finishReason"] as? String {
            throw GeminiError.blocked(reason)
        }
        throw GeminiError.emptyResponse
    }
}
