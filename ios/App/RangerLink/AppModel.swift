import Foundation
import Observation
import OBDCore

enum ConnectionKind: String, CaseIterable, Identifiable {
    case ble = "Bluetooth", wifi = "Wi-Fi", demo = "Demo"
    var id: String { rawValue }
}

enum ChatItem: Identifiable, Equatable {
    case user(UUID, String)
    case assistant(UUID, String)
    case thinking(UUID, String)
    case tool(UUID, name: String, input: String, output: String?, isError: Bool)
    case system(UUID, String)
    case raw(UUID, command: String, response: String)

    var id: UUID {
        switch self {
        case .user(let i, _), .assistant(let i, _), .thinking(let i, _), .system(let i, _): return i
        case .tool(let i, _, _, _, _), .raw(let i, _, _): return i
        }
    }
}

struct DriverPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let isConfirmation: Bool
    let resolve: (Bool) -> Void
}

@MainActor
@Observable
final class AppModel {
    // Base de datos
    let database: PIDDatabase

    // Conexión
    var kind: ConnectionKind = .demo
    var wifiHost = UserDefaults.standard.string(forKey: "wifiHost") ?? "192.168.0.10"
    var wifiPort = UserDefaults.standard.string(forKey: "wifiPort") ?? "35000"
    let ble = BLETransport()
    private(set) var elm: ELM327?
    private(set) var status = "Desconectado"
    private(set) var isConnecting = false
    private(set) var vehicleSummary: [String: String] = [:]

    // Log crudo
    private(set) var log: [LogLine] = []

    // En vivo
    var selectedIDs: [String] = UserDefaults.standard.stringArray(forKey: "selectedIDs")
        ?? ["OBD.01.0C", "OBD.01.05", "OBD.01.23", "OBD.01.0B", "OBD.01.42"]
    private(set) var live: [String: PIDReading] = [:]
    private(set) var history: [String: [(Date, Double)]] = [:]
    var liveRunning = false
    private var liveTask: Task<Void, Never>?

    // Claude
    var apiKey = Keychain.load("apiKey")
    var model = UserDefaults.standard.string(forKey: "model") ?? ClaudeConfig.defaultModel
    var effort = UserDefaults.standard.string(forKey: "effort") ?? "high"
    private(set) var chat: [ChatItem] = []
    private(set) var agentBusy = false
    private var agent: DiagnosticAgent?
    private var agentTask: Task<Void, Never>?
    var prompt: DriverPrompt?

    init() {
        database = AppModel.loadDatabase()
    }

    static func loadDatabase() -> PIDDatabase {
        guard let dir = Bundle.main.url(forResource: "pids", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return PIDDatabase() }
        let data = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
        return (try? PIDDatabase(jsonData: data)) ?? PIDDatabase()
    }

    func saveSettings() {
        Keychain.save(apiKey, account: "apiKey")
        UserDefaults.standard.set(model, forKey: "model")
        UserDefaults.standard.set(effort, forKey: "effort")
        UserDefaults.standard.set(wifiHost, forKey: "wifiHost")
        UserDefaults.standard.set(wifiPort, forKey: "wifiPort")
        agent = nil // se recrea con la configuración nueva, conservando nada del chat anterior
    }

    // MARK: - Conexión

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        stopLive()
        await elm?.transport.close()
        let transport: OBDTransport
        switch kind {
        case .ble: transport = ble
        case .wifi: transport = TCPTransport(host: wifiHost, port: UInt16(wifiPort) ?? 35000)
        case .demo: transport = SimulatedELM327(database: database)
        }
        let session = ELM327(transport: transport) { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        status = "Inicializando ELM327..."
        do {
            try await session.initialize()
            elm = session
            agent = nil
            status = "Conectado: \(transport.displayName)"
            await refreshVehicleInfo()
        } catch {
            elm = nil
            status = "Error: \(error)"
        }
    }

    func disconnect() async {
        stopLive()
        agentTask?.cancel()
        await elm?.transport.close()
        elm = nil
        agent = nil
        status = "Desconectado"
        vehicleSummary = [:]
    }

    private func refreshVehicleInfo() async {
        guard let elm else { return }
        var info: [String: String] = [:]
        info["Adaptador"] = await elm.adapterID
        info["Protocolo"] = await elm.protocolName
        info["Batería"] = await elm.batteryVoltage() ?? "?"
        info["VIN"] = await elm.vin() ?? "no disponible"
        if let s = try? await elm.supportedMode01() {
            info["PIDs modo 01"] = "\(s.count) soportados"
        }
        vehicleSummary = info
    }

    private func append(_ line: LogLine) {
        log.append(line)
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    func clearLog() { log = [] }

    var logText: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withTime, .withFractionalSeconds, .withColonSeparatorInTime]
        return log.map { "\(f.string(from: $0.time)) \($0.direction.rawValue) \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - En vivo

    func toggle(_ id: String) {
        if let i = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: i) } else { selectedIDs.append(id) }
        UserDefaults.standard.set(selectedIDs, forKey: "selectedIDs")
    }

    func startLive() {
        guard let elm, liveTask == nil else { return }
        liveRunning = true
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Cede el adaptador mientras Claude está midiendo.
                if self.agentBusy {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                let defs = self.selectedIDs.compactMap { self.database[$0] }
                if defs.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000); continue }
                let readings = await elm.read(defs)
                for r in readings {
                    self.live[r.id] = r
                    if let v = r.value {
                        var h = self.history[r.id] ?? []
                        h.append((r.time, v))
                        if h.count > 120 { h.removeFirst(h.count - 120) }
                        self.history[r.id] = h
                    }
                }
            }
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        liveRunning = false
    }

    // MARK: - Terminal / Claude

    func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t == "/reset" {
            chat = []
            Task { await agent?.reset() }
            return
        }
        if t.hasPrefix(">") {
            sendRaw(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        askClaude(t)
    }

    private func sendRaw(_ command: String) {
        guard let elm else { chat.append(.system(UUID(), "Conecta un adaptador primero.")); return }
        Task {
            var confirmed = false
            if case .needsConfirmation(let why) = SafetyGuard.check(command) {
                confirmed = await confirm(command, reason: why)
                guard confirmed else { chat.append(.system(UUID(), "Cancelado: \(command)")); return }
            }
            do {
                let r = try await elm.send(command, confirmed: confirmed)
                chat.append(.raw(UUID(), command: command, response: r.lines.joined(separator: "\n")))
            } catch {
                chat.append(.raw(UUID(), command: command, response: "\(error)"))
            }
        }
    }

    private func askClaude(_ text: String) {
        guard let elm else { chat.append(.system(UUID(), "Conecta un adaptador (o el modo Demo) primero.")); return }
        guard !apiKey.isEmpty else { chat.append(.system(UUID(), "Agrega tu API key de Anthropic en Ajustes.")); return }
        guard !agentBusy else { return }
        chat.append(.user(UUID(), text))
        var context: String?
        if agent == nil {
            let client = ClaudeClient(config: ClaudeConfig(apiKey: apiKey, model: model, effort: effort))
            agent = DiagnosticAgent(client: client, toolbox: AgentToolbox(elm: elm, database: database, driver: DriverBridge(model: self)))
            context = vehicleSummary.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        guard let agent else { return }
        agentBusy = true
        agentTask = Task {
            if let context { await agent.setConnectionContext(context) }
            await agent.run(text) { event in
                Task { @MainActor [weak self] in self?.handle(event) }
            }
            await MainActor.run { self.agentBusy = false }
        }
    }

    func cancelAgent() {
        agentTask?.cancel()
    }

    private func handle(_ e: AgentEvent) {
        switch e {
        case .text(let t): chat.append(.assistant(UUID(), t))
        case .thinking(let t): chat.append(.thinking(UUID(), t))
        case .toolCall(_, let name, let input): chat.append(.tool(UUID(), name: name, input: input, output: nil, isError: false))
        case .toolResult(_, let name, let output, let isError):
            if let i = chat.lastIndex(where: { if case .tool(_, let n, _, nil, _) = $0 { return n == name } else { return false } }),
               case .tool(let id, let n, let input, _, _) = chat[i] {
                chat[i] = .tool(id, name: n, input: input, output: output, isError: isError)
            }
        case .notice(let t): chat.append(.system(UUID(), t))
        case .error(let t): chat.append(.system(UUID(), "⚠️ " + t))
        case .finished: break
        }
    }

    // MARK: - Interacción con el conductor

    func ask(_ instruction: String) async -> Bool {
        await withCheckedContinuation { c in
            prompt = DriverPrompt(title: "Claude necesita una condición", message: instruction, isConfirmation: false) { ok in
                c.resume(returning: ok)
            }
        }
    }

    func confirm(_ command: String, reason: String) async -> Bool {
        await withCheckedContinuation { c in
            prompt = DriverPrompt(title: "¿Enviar \(command)?", message: reason, isConfirmation: true) { ok in
                c.resume(returning: ok)
            }
        }
    }
}

/// Puente Sendable entre el toolbox (fuera del MainActor) y la UI.
struct DriverBridge: DriverInteraction {
    weak var model: AppModel?

    func ask(_ instruction: String) async -> Bool {
        guard let model else { return false }
        return await model.ask(instruction)
    }

    func confirm(_ command: String, reason: String) async -> Bool {
        guard let model else { return false }
        return await model.confirm(command, reason: reason)
    }
}
