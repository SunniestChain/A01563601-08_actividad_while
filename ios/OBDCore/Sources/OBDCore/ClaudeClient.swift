import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cliente mínimo de la Messages API de Anthropic por HTTP (Swift no tiene SDK
/// oficial). Guarda los bloques de contenido como JSONValue para reenviarlos
/// intactos en el siguiente turno.
public struct ClaudeConfig: Sendable, Equatable {
    public var apiKey: String
    public var model: String
    public var effort: String
    public var maxTokens: Int
    public var baseURL: URL

    public init(apiKey: String, model: String = ClaudeConfig.defaultModel, effort: String = "high",
                maxTokens: Int = 16_000, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }

    public static let defaultModel = "claude-opus-5"
    public static let models = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Haiku 4.5 no acepta pensamiento adaptativo ni `effort`.
    var supportsAdaptiveThinking: Bool { !model.hasPrefix("claude-haiku") }
    /// `fallbacks: "default"` reintenta en otro modelo si un clasificador de
    /// seguridad rechaza la petición (aplica a Opus 5 / Fable).
    var supportsServerFallback: Bool { model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable") }
}

public struct ClaudeResponse: Sendable {
    public let raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var content: [JSONValue] { raw["content"]?.arrayValue ?? [] }
    public var stopReason: String { raw["stop_reason"]?.stringValue ?? "" }
    public var model: String { raw["model"]?.stringValue ?? "" }
    public var usage: JSONValue? { raw["usage"] }
}

public enum ClaudeError: Error, CustomStringConvertible {
    case missingKey
    case http(Int, String)
    case transport(String)
    case decode(String)

    public var description: String {
        switch self {
        case .missingKey: return "Falta la API key de Anthropic (Ajustes)."
        case .http(let code, let body):
            let msg = (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)))?["error"]?["message"]?.stringValue ?? body
            switch code {
            case 401: return "API key inválida (401)."
            case 429: return "Límite de uso alcanzado (429): \(msg)"
            case 529: return "API saturada (529), intenta de nuevo."
            default: return "HTTP \(code): \(msg)"
            }
        case .transport(let s): return "Red: \(s)"
        case .decode(let s): return "Respuesta inesperada: \(s)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .http(let c, _): return c == 429 || c == 408 || c >= 500
        case .transport: return true
        default: return false
        }
    }
}

/// Abstracción para poder probar el ciclo del agente sin red.
public protocol MessagesAPI: Sendable {
    func send(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ClaudeResponse
}

public final class ClaudeClient: MessagesAPI, @unchecked Sendable {
    public var config: ClaudeConfig
    private let session: URLSession

    public init(config: ClaudeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func buildBody(system: String, tools: [JSONValue], messages: [JSONValue]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "max_tokens": .int(config.maxTokens),
            "system": [["type": "text", "text": .string(system)]],
            "tools": .array(tools),
            "messages": .array(messages),
            // Caché automática del prefijo (tools + system + historial).
            "cache_control": ["type": "ephemeral"],
        ]
        if config.supportsAdaptiveThinking {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            body["output_config"] = ["effort": .string(config.effort)]
        }
        if config.supportsServerFallback {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    public func makeRequest(body: JSONValue) throws -> URLRequest {
        guard !config.apiKey.isEmpty else { throw ClaudeError.missingKey }
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if config.supportsServerFallback {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = Data(body.jsonString().utf8)
        return req
    }

    public func send(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ClaudeResponse {
        let request = try makeRequest(body: buildBody(system: system, tools: tools, messages: messages))
        var attempt = 0
        while true {
            do {
                return try await perform(request)
            } catch let e as ClaudeError where e.isRetryable && attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
        }
    }

    private func perform(_ request: URLRequest) async throws -> ClaudeResponse {
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { c in
            session.dataTask(with: request) { data, response, error in
                if let error { c.resume(throwing: ClaudeError.transport(error.localizedDescription)); return }
                guard let data, let response else { c.resume(throwing: ClaudeError.transport("sin datos")); return }
                c.resume(returning: (data, response))
            }.resume()
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ClaudeError.http(code, String(decoding: data, as: UTF8.self)) }
        do {
            return ClaudeResponse(raw: try JSONDecoder().decode(JSONValue.self, from: data))
        } catch {
            throw ClaudeError.decode("\(error)")
        }
    }
}
