import Foundation

public struct LogLine: Sendable, Identifiable, Equatable {
    public enum Direction: String, Sendable { case tx = "→", rx = "←", info = "·" }
    public let id = UUID()
    public let time: Date
    public let direction: Direction
    public let text: String
}

public struct PIDReading: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let value: Double?
    public let unit: String
    public let raw: String?
    public let error: String?
    public let time: Date
}

public struct SignalStats: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let unit: String
    public let count: Int
    public let min: Double?
    public let max: Double?
    public let mean: Double?
    public let stddev: Double?
    public let last: Double?
    /// Serie reducida (t en segundos desde el inicio, valor).
    public let series: [[Double]]
    public let errors: Int
    public let lastError: String?
}

public enum ELMError: Error, CustomStringConvertible, Equatable {
    case blocked(String)
    case needsConfirmation(String)
    case adapter(String)

    public var description: String {
        switch self {
        case .blocked(let s): return "bloqueado por seguridad: \(s)"
        case .needsConfirmation(let s): return "requiere confirmación del usuario: \(s)"
        case .adapter(let s): return s
        }
    }
}

/// Sesión con un ELM327 (o compatible STN/OBDLink). Es un actor: serializa todos
/// los comandos, así el tablero en vivo y las herramientas de Claude pueden
/// compartir el mismo adaptador sin pisarse.
public actor ELM327 {
    public let transport: OBDTransport
    private let logger: @Sendable (LogLine) -> Void
    private var header: String?
    private var receiveFilter: String?
    public private(set) var adapterID = ""
    public private(set) var protocolName = ""
    private var supportedCache: Set<String>?

    public init(transport: OBDTransport, logger: @escaping @Sendable (LogLine) -> Void = { _ in }) {
        self.transport = transport
        self.logger = logger
    }

    private func log(_ d: LogLine.Direction, _ t: String) {
        logger(LogLine(time: Date(), direction: d, text: t))
    }

    // MARK: - Comandos crudos

    /// Envía un comando pasando por SafetyGuard. `confirmed` sólo lo pone la UI
    /// después de que el usuario aprobó explícitamente.
    public func send(_ command: String, confirmed: Bool = false, timeout: TimeInterval = 4) async throws -> ELMResponse {
        switch SafetyGuard.check(command) {
        case .allowed: break
        case .needsConfirmation(let why) where !confirmed: throw ELMError.needsConfirmation(why)
        case .needsConfirmation: break
        case .blocked(let why):
            log(.info, "BLOQUEADO \(command): \(why)")
            throw ELMError.blocked(why)
        }
        let cmd = SafetyGuard.normalize(command)
        log(.tx, cmd)
        let raw = try await transport.transact(cmd, timeout: timeout)
        let trimmed = raw.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        log(.rx, trimmed.isEmpty ? "(vacío)" : trimmed)
        return ELMResponseParser.parse(raw)
    }

    /// Selecciona el módulo destino (cabecera CAN de 11 bits) y el filtro de respuesta.
    public func select(tx: String, rx: String?) async throws {
        if header != tx {
            _ = try await send("ATSH" + tx)
            header = tx
        }
        let wanted = rx ?? "AR"
        if receiveFilter != wanted {
            _ = try await send(rx.map { "ATCRA" + $0 } ?? "ATAR")
            receiveFilter = wanted
        }
    }

    public func request(tx: String, rx: String?, command: String, confirmed: Bool = false) async throws -> ELMResponse {
        try await select(tx: tx, rx: rx)
        return try await send(command, confirmed: confirmed)
    }

    // MARK: - Inicialización

    public func initialize() async throws {
        header = nil
        receiveFilter = nil
        supportedCache = nil
        try await transport.open()
        _ = try await send("ATZ", timeout: 5)
        adapterID = (try? await send("ATI"))?.lines.last ?? ""
        for c in ["ATE0", "ATL0", "ATS1", "ATH1", "ATCAF1", "ATAT1", "ATSP6"] {
            let r = try await send(c)
            if r.status == .unknownCommand { log(.info, "el adaptador no entiende \(c)") }
        }
        let probe = try await request(tx: "7E0", rx: "7E8", command: "0100")
        if probe.firstPositive == nil {
            throw ELMError.adapter("la PCM no respondió a 0100 (\(probe.status.rawValue)). ¿Encendido en ON?")
        }
        protocolName = (try? await send("ATDP"))?.lines.last ?? ""
    }

    public func batteryVoltage() async -> String? {
        (try? await send("ATRV"))?.lines.last
    }

    public func vin() async -> String? {
        guard let r = try? await request(tx: "7E0", rx: "7E8", command: "0902"),
              let m = r.firstPositive, m.payload.count > 3 else { return nil }
        let chars = m.payload.dropFirst(3).filter { $0 >= 0x20 && $0 < 0x7F }
        return String(decoding: chars, as: UTF8.self)
    }

    /// PIDs de modo 01 soportados por la PCM, leyendo las máscaras 00/20/40...
    public func supportedMode01() async throws -> Set<String> {
        if let c = supportedCache { return c }
        var out = Set<String>()
        var base: UInt8 = 0x00
        while true {
            let r = try await request(tx: "7E0", rx: "7E8", command: String(format: "01%02X", base))
            guard let m = r.firstPositive, m.payload.count >= 6 else { break }
            let mask = m.payload[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            for bit in 0..<32 where mask & (UInt32(1) << (31 - UInt32(bit))) != 0 {
                out.insert(String(format: "%02X", Int(base) + bit + 1))
            }
            guard mask & 1 != 0, base < 0xE0 else { break }
            base += 0x20
        }
        supportedCache = out
        return out
    }

    // MARK: - Lectura de PIDs

    public func read(_ pids: [PIDDefinition]) async -> [PIDReading] {
        var out: [PIDReading] = []
        var groups: [String: [PIDDefinition]] = [:]
        var order: [String] = []
        for p in pids {
            if groups[p.requestKey] == nil { order.append(p.requestKey) }
            groups[p.requestKey, default: []].append(p)
        }
        for key in order {
            guard let group = groups[key], let first = group.first else { continue }
            let now = Date()
            do {
                let r = try await request(tx: first.tx, rx: first.rx, command: first.command)
                let echo = first.echo
                let msg = r.messages.first { $0.payload.starts(with: echo) }
                let neg = r.messages.first { $0.isNegative }
                for p in group {
                    if let msg {
                        do {
                            let v = try p.decode(payload: msg.payload)
                            out.append(PIDReading(id: p.id, name: p.name_es, value: v, unit: p.unit, raw: Hex.string(msg.payload), error: nil, time: now))
                        } catch {
                            out.append(PIDReading(id: p.id, name: p.name_es, value: nil, unit: p.unit, raw: Hex.string(msg.payload), error: "\(error)", time: now))
                        }
                    } else {
                        let why = neg.flatMap { $0.negativeCode }.map { "respuesta negativa: " + ELMResponseParser.nrcName($0) }
                            ?? (r.status == .ok ? "respuesta sin eco esperado" : r.status.rawValue)
                        out.append(PIDReading(id: p.id, name: p.name_es, value: nil, unit: p.unit, raw: r.lines.joined(separator: " | "), error: why, time: now))
                    }
                }
            } catch {
                for p in group {
                    out.append(PIDReading(id: p.id, name: p.name_es, value: nil, unit: p.unit, raw: nil, error: "\(error)", time: now))
                }
            }
        }
        return out
    }

    /// Muestrea señales durante `duration` segundos. Devuelve estadísticas y una
    /// serie reducida a `maxPoints` puntos por señal (para no inflar el contexto).
    public func sample(_ pids: [PIDDefinition], duration: TimeInterval, interval: TimeInterval, maxPoints: Int = 40) async -> [SignalStats] {
        let start = Date()
        var series: [String: [(Double, Double)]] = [:]
        var errors: [String: (Int, String)] = [:]
        while Date().timeIntervalSince(start) < duration, !Task.isCancelled {
            let loopStart = Date()
            for r in await read(pids) {
                let t = r.time.timeIntervalSince(start)
                if let v = r.value { series[r.id, default: []].append((t, v)) }
                if let e = r.error { errors[r.id] = ((errors[r.id]?.0 ?? 0) + 1, e) }
            }
            let spent = Date().timeIntervalSince(loopStart)
            if spent < interval {
                try? await Task.sleep(nanoseconds: UInt64((interval - spent) * 1_000_000_000))
            }
        }
        return pids.map { p in
            let s = series[p.id] ?? []
            let vals = s.map(\.1)
            let mean = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
            let sd = mean.map { m in (vals.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(vals.count)).squareRoot() }
            let step = max(1, Int((Double(s.count) / Double(maxPoints)).rounded(.up)))
            let reduced = stride(from: 0, to: s.count, by: step).map { [round2(s[$0].0), round3(s[$0].1)] }
            return SignalStats(id: p.id, name: p.name_es, unit: p.unit, count: vals.count,
                               min: vals.min(), max: vals.max(), mean: mean.map(round3), stddev: sd.map(round3),
                               last: vals.last, series: reduced, errors: errors[p.id]?.0 ?? 0, lastError: errors[p.id]?.1)
        }
    }

    // MARK: - DTCs

    /// Códigos OBD genéricos: almacenados (03), pendientes (07), permanentes (0A).
    public func obdDTCs() async -> [String: [DTC]] {
        var out: [String: [DTC]] = [:]
        for (name, cmd) in [("almacenados", "03"), ("pendientes", "07"), ("permanentes", "0A")] {
            guard let r = try? await request(tx: "7DF", rx: nil, command: cmd) else { continue }
            out[name] = r.messages.flatMap { DTCDecoder.obdDTCs(payload: $0.payload, module: $0.header) }
        }
        return out
    }

    /// DTCs UDS de un módulo (19 02 FF: todos los estados).
    public func udsDTCs(tx: String, rx: String, module: String) async throws -> [DTC] {
        let r = try await request(tx: tx, rx: rx, command: "1902FF")
        if let neg = r.messages.first(where: \.isNegative), let c = neg.negativeCode {
            throw ELMError.adapter("\(module) respondió negativo: \(ELMResponseParser.nrcName(c))")
        }
        return r.messages.flatMap { DTCDecoder.udsDTCs(payload: $0.payload, module: module) }
    }
}

private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
