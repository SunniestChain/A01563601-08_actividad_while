import Foundation

/// ELM327 simulado: responde como una Ranger PX 3.2 en ralentí con aceleradas
/// periódicas. Sirve para probar la app y la terminal de Claude sin la camioneta.
///
/// Los valores físicos se definen por id de PID; los bytes se obtienen invirtiendo
/// la fórmula de la base de datos por fuerza bruta (1 o 2 bytes por señal), así
/// que cualquier PID nuevo de la base funciona en el simulador si se le da un
/// valor en `scenario`.
public final class SimulatedELM327: OBDTransport, @unchecked Sendable {
    public let displayName = "Simulador (Ranger PX 3.2 demo)"
    private let lock = NSLock()
    private let db: PIDDatabase
    private var header = "7DF"
    private var headersOn = true
    private let start = Date()
    private var cache: [String: [UInt8]] = [:]

    /// Valor físico por id de PID en función del tiempo (s) y RPM actuales.
    public var scenario: [String: @Sendable (_ t: Double, _ rpm: Double) -> Double]

    /// Módulos que "existen" en el simulador (cabecera de petición → respuesta).
    public var modules: [String: String] = ["7E0": "7E8", "7E1": "7E9", "760": "768", "720": "728", "726": "72E"]

    public init(database: PIDDatabase) {
        db = database
        scenario = SimulatedELM327.defaultScenario
    }

    public func open() async throws {}
    public func close() async {}

    public func transact(_ line: String, timeout: TimeInterval) async throws -> String {
        try await Task.sleep(nanoseconds: 15_000_000) // ~latencia de un BLE barato
        lock.lock(); defer { lock.unlock() }
        return respond(SafetyGuard.normalize(line)) + "\r\r>"
    }

    // MARK: - Escenario

    /// RPM: ralentí 780 con ruido; cada 30 s acelera a ~2500 durante 6 s.
    public static func rpm(_ t: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: 30)
        let base = phase > 20 && phase < 26 ? 2500.0 : 780.0
        return base + 12 * sin(t * 3.1)
    }

    public static let defaultScenario: [String: @Sendable (Double, Double) -> Double] = [
        "OBD.01.04": { _, r in r > 1500 ? 38 : 19 },
        "OBD.01.05": { t, _ in min(89, 60 + t / 10) },
        "OBD.01.0B": { _, r in r > 1500 ? 175 : 101 },
        "OBD.01.0C": { _, r in r },
        "OBD.01.0D": { _, _ in 0 },
        "OBD.01.0F": { _, _ in 31 },
        "OBD.01.10": { _, r in r / 780 * 9.5 },
        "OBD.01.11": { _, _ in 100 },
        "OBD.01.1F": { t, _ in t + 120 },
        "OBD.01.23": { _, r in r > 1500 ? 98_000 : 33_000 },
        "OBD.01.2C": { _, r in r > 1500 ? 5 : 32 },
        "OBD.01.2F": { _, _ in 62 },
        "OBD.01.31": { _, _ in 4_812 },
        "OBD.01.33": { _, _ in 85 },
        "OBD.01.42": { t, _ in 14.1 + 0.05 * sin(t) },
        "OBD.01.46": { _, _ in 27 },
        "OBD.01.49": { _, r in r > 1500 ? 28 : 0 },
        "OBD.01.5E": { _, r in r > 1500 ? 6.2 : 1.1 },
        "OBD.01.63": { _, _ in 470 },
        // Ford modo 22
        "PCM.22.F45C": { t, _ in min(88, 55 + t / 12) },
        "PCM.22.F42F": { _, _ in 62 },
        "PCM.22.F40C": { _, r in r },
        "PCM.22.F423": { _, r in r > 1500 ? 98_000 : 33_000 },
        "PCM.22.057B": { _, _ in 27 },
        "PCM.22.060E": { _, _ in 0 },
        "TCM.22.1E1C": { t, _ in min(71, 40 + t / 20) },
        "TCM.22.1E12": { _, _ in 1 },
        "TCM.22.1E23": { _, _ in 0x46 },
        // Escenario de demo: el cilindro 5 pide bastante más corrección que los demás.
        "PCM.22.6043": { t, _ in 0.5 + 0.5 * sin(t) },
        "PCM.22.6063": { t, _ in -1.0 + 0.5 * sin(t * 1.3) },
        "PCM.22.6049": { t, _ in 1.0 + 0.5 * sin(t * 0.7) },
        "PCM.22.6069": { t, _ in -0.5 + 0.5 * sin(t * 1.1) },
        "PCM.22.3037": { t, _ in 6.5 + 0.5 * sin(t * 0.9) },
    ]

    // MARK: - Protocolo

    private func respond(_ c: String) -> String {
        if c.hasPrefix("AT") { return at(String(c.dropFirst(2))) }
        let req = Hex.bytes(c)
        guard let sid = req.first else { return "?" }
        guard let rx = header == "7DF" ? "7E8" : modules[header] else { return "NO DATA" }
        let t = Date().timeIntervalSince(start)
        let r = SimulatedELM327.rpm(t)

        var payload: [UInt8]?
        switch sid {
        case 0x01 where req.count == 2:
            payload = mode01(req[1], rx: rx, t: t, rpm: r)
        case 0x03:
            payload = rx == "7E8" ? [0x43, 0x01, 0x04, 0x01] : [0x43, 0x00]   // P0401
        case 0x07, 0x0A:
            payload = [sid + 0x40, 0x00]
        case 0x09 where req.count == 2 && req[1] == 0x02:
            payload = [0x49, 0x02, 0x01] + Array("MNCUMFF80DW000000".utf8)  // VIN ficticio
        case 0x19 where req.count >= 2 && req[1] == 0x02:
            payload = rx == "7E8" ? [0x59, 0x02, 0xFF, 0x04, 0x01, 0x00, 0x2F] : [0x59, 0x02, 0xFF]
        case 0x22 where req.count == 3:
            payload = did(req, rx: rx, t: t, rpm: r)
        case 0x10:
            payload = [0x50, req.count > 1 ? req[1] : 1, 0x00, 0x32, 0x01, 0xF4]
        case 0x3E:
            payload = [0x7E, 0x00]
        default:
            payload = [0x7F, sid, 0x11]
        }
        guard let payload else { return "NO DATA" }
        return frames(rx: rx, payload: payload)
    }

    private func at(_ c: String) -> String {
        switch true {
        case c == "Z": header = "7DF"; return "\r\rELM327 v1.5"
        case c == "I": return "ELM327 v1.5"
        case c == "RV": return String(format: "%.1fV", 14.1 + 0.05 * sin(Date().timeIntervalSince(start)))
        case c == "DP": return "ISO 15765-4 (CAN 11/500)"
        case c == "DPN": return "6"
        case c == "H0": headersOn = false; return "OK"
        case c == "H1": headersOn = true; return "OK"
        case c.hasPrefix("SH"): header = String(c.dropFirst(2)); return "OK"
        default: return "OK"
        }
    }

    private func mode01(_ pid: UInt8, rx: String, t: Double, rpm: Double) -> [UInt8]? {
        guard rx == "7E8" else { return nil }
        let hex = String(format: "%02X", pid)
        if pid % 0x20 == 0 { return [0x41, pid] + supportMask(base: pid) }
        let defs = db.pids.filter { $0.service == "01" && $0.pid == hex }
        return build(defs, t: t, rpm: rpm)
    }

    private func did(_ req: [UInt8], rx: String, t: Double, rpm: Double) -> [UInt8]? {
        let hex = String(format: "%02X%02X", req[1], req[2])
        let defs = db.pids.filter { $0.service == "22" && $0.pid == hex && $0.rx == rx }
        return build(defs, t: t, rpm: rpm) ?? [0x7F, 0x22, 0x31]
    }

    private func supportMask(base: UInt8) -> [UInt8] {
        var mask: UInt32 = 0
        let supported = Set(db.pids.filter { $0.service == "01" && scenario[$0.id] != nil }.compactMap { UInt8($0.pid, radix: 16) })
        for p in supported where p > base && p <= base &+ 0x20 {
            mask |= UInt32(1) << UInt32(0x20 - Int(p - base))
        }
        if supported.contains(where: { $0 > base &+ 0x20 }) { mask |= 1 }
        return [UInt8(mask >> 24), UInt8(mask >> 16 & 0xFF), UInt8(mask >> 8 & 0xFF), UInt8(mask & 0xFF)]
    }

    private func build(_ defs: [PIDDefinition], t: Double, rpm: Double) -> [UInt8]? {
        let active = defs.filter { scenario[$0.id] != nil }
        guard let first = active.first ?? defs.first else { return nil }
        guard !active.isEmpty else { return nil }
        var data = [UInt8](repeating: 0, count: max(first.bytes, 1))
        for d in active {
            guard let f = try? Formula(d.formula), let target = scenario[d.id]?(t, rpm) else { continue }
            for (i, b) in invert(f, target: target, template: data, id: d.id) { if i < data.count { data[i] = b } }
        }
        return first.echo + data
    }

    /// Busca los bytes que mejor reproducen `target`. Soporta fórmulas de 1-2 bytes.
    private func invert(_ f: Formula, target: Double, template: [UInt8], id: String) -> [(Int, UInt8)] {
        let idx = f.byteIndices
        guard !idx.isEmpty, idx.count <= 2, idx.allSatisfy({ $0 < template.count }) else { return [] }
        let key = "\(id)|\(String(format: "%.4g", target))"
        if let c = cache[key] { return Array(zip(idx, c)) }
        var best: [UInt8] = Array(repeating: 0, count: idx.count)
        var bestErr = Double.infinity
        var data = template
        let hiRange = idx.count == 2 ? 0...255 : 0...0
        for hi in hiRange {
            for lo in 0...255 {
                if idx.count == 2 { data[idx[0]] = UInt8(hi); data[idx[1]] = UInt8(lo) } else { data[idx[0]] = UInt8(lo) }
                guard let v = try? f.evaluate(data) else { continue }
                let e = Swift.abs(v - target)
                if e < bestErr { bestErr = e; best = idx.map { data[$0] } }
            }
        }
        cache[key] = best
        return Array(zip(idx, best))
    }

    private func frames(rx: String, payload: [UInt8]) -> String {
        let h = headersOn ? rx + " " : ""
        if payload.count <= 7 {
            return h + Hex.string([UInt8(payload.count)] + payload)
        }
        var lines = [h + Hex.string([0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload.prefix(6))]
        var rest = Array(payload.dropFirst(6))
        var seq: UInt8 = 1
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(7))
            rest = Array(rest.dropFirst(7))
            lines.append(h + Hex.string([0x20 | seq] + chunk + Array(repeating: 0x00, count: 7 - chunk.count)))
            seq = (seq + 1) & 0x0F
        }
        return lines.joined(separator: "\r")
    }
}
