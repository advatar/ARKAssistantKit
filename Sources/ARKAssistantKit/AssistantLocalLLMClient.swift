import Foundation

#if os(macOS) && canImport(GemmaKit)
import GemmaKit
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class AssistantLocalLLMClient {
    struct Response: Sendable {
        let text: String
        let providerLabel: String
    }

    enum ClientError: LocalizedError {
        case unavailable
        case invalidEndpoint
        case badStatus(Int)
        case noModel
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "No local assistant model is available."
            case .invalidEndpoint:
                return "Local assistant endpoint is invalid."
            case .badStatus(let status):
                return "Local assistant endpoint returned \(status)."
            case .noModel:
                return "No local assistant model was reported."
            case .emptyResponse:
                return "The local assistant model returned no response."
            }
        }
    }

#if os(macOS) && canImport(GemmaKit)
    private var gemmaSession: GemmaSession?
#endif

    func statusText() -> String {
#if os(macOS) && canImport(GemmaKit)
        if (try? GemmaModelLocator().resolveModelPath()) != nil {
            return "Model: Gemma 4 (local)"
        }
#endif
        if Self.appleFoundationModelsAvailable {
            return "Model: Apple Foundation Models"
        }
        if Self.swiftLMEnabled || Self.ollamaEnabled {
            return "Model: Gemma-first local ladder"
        }
        return "Model: unavailable"
    }

    var canAttemptResponse: Bool {
#if os(macOS) && canImport(GemmaKit)
        if (try? GemmaModelLocator().resolveModelPath()) != nil {
            return true
        }
#endif
        return Self.swiftLMEnabled || Self.ollamaEnabled || Self.appleFoundationModelsAvailable
    }

    func response(prompt: String, instructions: String) async throws -> Response {
        if let response = try? await gemmaKitResponse(prompt: prompt, instructions: instructions) {
            return response
        }
        if let response = try? await appleFoundationModelsResponse(prompt: prompt, instructions: instructions) {
            return response
        }
        if let response = try? await openAICompatibleResponse(
            baseURL: Self.swiftLMBaseURL,
            modelOverride: Self.swiftLMModelOverride,
            providerPrefix: "SwiftLM",
            timeout: Self.swiftLMTimeout,
            prompt: prompt,
            instructions: instructions,
            enabled: Self.swiftLMEnabled
        ) {
            return response
        }
        if let response = try? await ollamaResponse(prompt: prompt, instructions: instructions) {
            return response
        }
        throw ClientError.unavailable
    }

    private func gemmaKitResponse(prompt: String, instructions: String) async throws -> Response {
#if os(macOS) && canImport(GemmaKit)
        guard let modelURL = try? GemmaModelLocator().resolveModelPath() else {
            throw ClientError.unavailable
        }
        let session: GemmaSession
        if let existing = gemmaSession {
            session = existing
        } else {
            let fresh = GemmaSession(modelPath: modelURL)
            gemmaSession = fresh
            session = fresh
        }
        let text = try await session.respond(system: instructions, to: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return Response(text: text, providerLabel: "Gemma 4")
#else
        let _ = prompt
        let _ = instructions
        throw ClientError.unavailable
#endif
    }

    private func openAICompatibleResponse(
        baseURL: URL,
        modelOverride: String?,
        providerPrefix: String,
        timeout: TimeInterval,
        prompt: String,
        instructions: String,
        enabled: Bool
    ) async throws -> Response {
        guard enabled else { throw ClientError.unavailable }
        let model = try await resolveOpenAIModel(baseURL: baseURL, override: modelOverride, timeout: timeout)
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(
                model: model,
                messages: [
                    .init(role: "system", content: instructions),
                    .init(role: "user", content: prompt)
                ],
                temperature: 0.2,
                stream: false
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidEndpoint }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return Response(text: text, providerLabel: "\(providerPrefix): \(model)")
    }

    private func resolveOpenAIModel(baseURL: URL, override: String?, timeout: TimeInterval) async throws -> String {
        if let override, !override.isEmpty { return override }
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidEndpoint }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(OpenAIModelList.self, from: data)
        let ids = decoded.data.map(\.id)
        guard let model = ids.first(where: { $0.lowercased().contains("gemma") }) ?? ids.first else {
            throw ClientError.noModel
        }
        return model
    }

    private func ollamaResponse(prompt: String, instructions: String) async throws -> Response {
        guard Self.ollamaEnabled else { throw ClientError.unavailable }
        let model = Self.ollamaModelOverride ?? "gemma3:latest"
        let endpoint = Self.ollamaBaseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: endpoint, timeoutInterval: Self.ollamaTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaGenerateRequest(
                model: model,
                prompt: "\(instructions)\n\n\(prompt)",
                stream: false,
                options: OllamaGenerateOptions(temperature: 0.2)
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidEndpoint }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        let text = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return Response(text: text, providerLabel: "Ollama: \(model)")
    }

    private func appleFoundationModelsResponse(prompt: String, instructions: String) async throws -> Response {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard Self.appleFoundationModelsAvailable else { throw ClientError.unavailable }
            let session = LanguageModelSession(instructions: Instructions(instructions))
            let response = try await session.respond(to: Prompt(prompt), options: GenerationOptions(temperature: 0.2))
            let text = String(describing: response.content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ClientError.emptyResponse }
            return Response(text: text, providerLabel: "Apple Foundation Models")
        }
#endif
        let _ = prompt
        let _ = instructions
        throw ClientError.unavailable
    }

    private static var appleFoundationModelsAvailable: Bool {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
#endif
        return false
    }

    private static var swiftLMEnabled: Bool {
        boolEnv(["ARK_ASSISTANT_SWIFTLM_ENABLED", "ARK_SESSION_CLAIMS_SWIFTLM_ENABLED", "ARK_SWIFTLM_ENABLED"], defaultValue: true)
    }

    private static var swiftLMBaseURL: URL {
        urlEnv(["ARK_ASSISTANT_SWIFTLM_BASE_URL", "ARK_SESSION_CLAIMS_SWIFTLM_BASE_URL", "ARK_SWIFTLM_BASE_URL"])
            ?? URL(string: "http://127.0.0.1:8400")!
    }

    private static var swiftLMModelOverride: String? {
        stringEnv(["ARK_ASSISTANT_SWIFTLM_MODEL", "ARK_SESSION_CLAIMS_SWIFTLM_MODEL", "ARK_SWIFTLM_MODEL"])
    }

    private static var swiftLMTimeout: TimeInterval {
        timeIntervalEnv(["ARK_ASSISTANT_SWIFTLM_TIMEOUT_SECONDS", "ARK_SESSION_CLAIMS_SWIFTLM_TIMEOUT_SECONDS"], defaultValue: 10)
    }

    private static var ollamaEnabled: Bool {
        boolEnv(["ARK_ASSISTANT_GEMMA_ENABLED", "ARK_SESSION_CLAIMS_GEMMA_ENABLED", "ARK_GEMMA_ENABLED"], defaultValue: true)
    }

    private static var ollamaBaseURL: URL {
        urlEnv(["ARK_ASSISTANT_GEMMA_BASE_URL", "ARK_SESSION_CLAIMS_GEMMA_BASE_URL", "ARK_GEMMA_BASE_URL"])
            ?? URL(string: "http://127.0.0.1:11434")!
    }

    private static var ollamaModelOverride: String? {
        stringEnv(["ARK_ASSISTANT_GEMMA_MODEL", "ARK_SESSION_CLAIMS_GEMMA_MODEL", "ARK_GEMMA_MODEL"])
    }

    private static var ollamaTimeout: TimeInterval {
        timeIntervalEnv(["ARK_ASSISTANT_GEMMA_TIMEOUT_SECONDS", "ARK_SESSION_CLAIMS_GEMMA_TIMEOUT_SECONDS", "ARK_GEMMA_TIMEOUT_SECONDS"], defaultValue: 8)
    }

    private static func boolEnv(_ keys: [String], defaultValue: Bool) -> Bool {
        guard let raw = keys.compactMap({ ProcessInfo.processInfo.environment[$0] }).first else {
            return defaultValue
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["0", "false", "no", "off"].contains(normalized) { return false }
        if ["1", "true", "yes", "on"].contains(normalized) { return true }
        return defaultValue
    }

    private static func stringEnv(_ keys: [String]) -> String? {
        let raw = keys.compactMap { ProcessInfo.processInfo.environment[$0] }.first
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func urlEnv(_ keys: [String]) -> URL? {
        guard let raw = stringEnv(keys), let url = URL(string: raw), url.scheme?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func timeIntervalEnv(_ keys: [String], defaultValue: TimeInterval) -> TimeInterval {
        guard let raw = stringEnv(keys), let value = TimeInterval(raw), value > 0 else {
            return defaultValue
        }
        return value
    }
}

private struct OpenAIModelList: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: OllamaGenerateOptions
}

private struct OllamaGenerateOptions: Encodable {
    let temperature: Double
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}
