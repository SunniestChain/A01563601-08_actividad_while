import Foundation

public struct PIDTest: Codable, Sendable, Equatable {
    public let response: String
    public let expect: Double
}

/// Una señal decodificable. Varias entradas pueden compartir la misma petición
/// (mismo módulo + servicio + PID), p. ej. 01 78 trae varias EGT.
public struct PIDDefinition: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let module: String
    public let tx: String
    public let rx: String
    public let service: String
    public let pid: String
    public let name_en: String
    public let name_es: String
    public let category: String
    public let bytes: Int
    public let formula: String
    public let unit: String
    public let min: Double?
    public let max: Double?
    public let signed: Bool?
    public let confidence: String
    public let sources: [String]?
    public let notes: String?
    public let test: PIDTest?

    /// Comando OBD en hex sin espacios, p. ej. "010C" o "22F40C".
    public var command: String { service + pid }

    /// Llave para agrupar señales que salen de la misma respuesta.
    public var requestKey: String { "\(tx)|\(command)" }

    /// Bytes de eco que preceden a los datos: servicio+0x40 y el PID/DID.
    public var echo: [UInt8] {
        let svc = UInt8(service, radix: 16) ?? 0
        return [svc &+ 0x40] + Hex.bytes(pid)
    }

    /// Extrae A, B, C... de un payload UDS completo (sin PCI).
    public func dataBytes(fromPayload payload: [UInt8]) -> [UInt8]? {
        let e = echo
        guard payload.count >= e.count, Array(payload.prefix(e.count)) == e else { return nil }
        return Array(payload.dropFirst(e.count))
    }

    public func decode(payload: [UInt8]) throws -> Double {
        guard let data = dataBytes(fromPayload: payload) else {
            throw DecodeError.echoMismatch(expected: Hex.string(echo), got: Hex.string(payload))
        }
        return try Formula(formula).evaluate(data)
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case echoMismatch(expected: String, got: String)
        public var description: String {
            switch self {
            case .echoMismatch(let e, let g): return "la respuesta \(g) no empieza con \(e)"
            }
        }
    }
}

/// DID que existe según alguna fuente pero cuya fórmula/escala no se conoce.
/// Claude puede leerlo crudo con read_did y cruzarlo con señales conocidas.
public struct DIDCandidate: Codable, Sendable, Equatable {
    public let module: String
    public let tx: String
    public let rx: String
    public let did: String
    public let name_es: String
    public let notes: String?
}

public struct PIDFile: Codable, Sendable {
    public let schema_version: Int
    public let title: String
    public let pids: [PIDDefinition]
    public let candidates: [DIDCandidate]?
}

public struct PIDDatabase: Sendable {
    public private(set) var pids: [PIDDefinition] = []
    public private(set) var candidates: [DIDCandidate] = []
    private var byID: [String: PIDDefinition] = [:]

    public init(files: [PIDFile] = []) {
        for f in files {
            add(f.pids)
            candidates += f.candidates ?? []
        }
    }

    public init(jsonData: [Data]) throws {
        let dec = JSONDecoder()
        self.init(files: try jsonData.map { try dec.decode(PIDFile.self, from: $0) })
    }

    public mutating func add(_ list: [PIDDefinition]) {
        for p in list where byID[p.id] == nil {
            pids.append(p)
            byID[p.id] = p
        }
    }

    public subscript(id: String) -> PIDDefinition? { byID[id] }

    public func search(_ text: String) -> [PIDDefinition] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return pids }
        return pids.filter {
            "\($0.id) \($0.name_es) \($0.name_en) \($0.category) \($0.module)".lowercased().contains(q)
        }
    }

    public var modules: [String] { Array(Set(pids.map(\.module))).sorted() }

    /// Catálogo compacto para el system prompt de Claude (una línea por señal).
    public func compactCatalog() -> String {
        let lines = pids.map { p in
            let range = [p.min, p.max].compactMap { $0 }.map { String(format: "%g", $0) }.joined(separator: "..")
            return "\(p.id) | \(p.module) \(p.tx)->\(p.rx) \(p.command) | \(p.name_es) [\(p.unit)\(range.isEmpty ? "" : " " + range)] | \(p.confidence)"
        }
        let cand = candidates.map { "\($0.module) \($0.tx)->\($0.rx) 22\($0.did) | \($0.name_es) | \($0.notes ?? "")" }
        return lines.joined(separator: "\n")
            + (cand.isEmpty ? "" : "\n\nDIDs candidatos sin fórmula conocida (leer crudo con read_did):\n" + cand.joined(separator: "\n"))
    }
}

public enum Hex {
    public static func bytes(_ s: String) -> [UInt8] {
        let clean = s.filter { $0.isHexDigit }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex, let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) {
            if let b = UInt8(clean[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }

    public static func string(_ b: [UInt8], separator: String = " ") -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: separator)
    }
}
