import Foundation

public struct DTC: Sendable, Equatable, Codable {
    public let code: String          // P0401, U0100...
    public let failureType: UInt8?   // UDS: tercer byte (FTB)
    public let status: UInt8?        // UDS: byte de estado
    public let module: String

    public var displayCode: String {
        guard let ft = failureType else { return code }
        return code + String(format: "-%02X", ft)
    }

    /// Descripción corta de los bits de estado ISO 14229.
    public var statusText: String? {
        guard let s = status else { return nil }
        var out: [String] = []
        if s & 0x01 != 0 { out.append("falla ahora") }
        if s & 0x04 != 0 { out.append("pendiente") }
        if s & 0x08 != 0 { out.append("confirmado") }
        if s & 0x80 != 0 { out.append("pide testigo") }
        return out.isEmpty ? "histórico" : out.joined(separator: ", ")
    }
}

public enum DTCDecoder {
    static let letters: [Character] = ["P", "C", "B", "U"]

    public static func code(_ hi: UInt8, _ lo: UInt8) -> String {
        let letter = letters[Int(hi >> 6)]
        let d1 = (hi >> 4) & 0x03
        return "\(letter)\(d1)" + String(format: "%X%02X", hi & 0x0F, lo)
    }

    /// Respuesta de servicios 03/07/0A: 43 [n] AA BB AA BB ... (en CAN, n = cantidad).
    public static func obdDTCs(payload: [UInt8], module: String) -> [DTC] {
        guard let first = payload.first, [0x43, 0x47, 0x4A].contains(first) else { return [] }
        var body = Array(payload.dropFirst())
        if body.count % 2 == 1 { body = Array(body.dropFirst()) } // byte de cantidad en CAN
        var out: [DTC] = []
        var i = 0
        while i + 1 < body.count {
            if body[i] != 0 || body[i + 1] != 0 {
                out.append(DTC(code: code(body[i], body[i + 1]), failureType: nil, status: nil, module: module))
            }
            i += 2
        }
        return out
    }

    /// Respuesta UDS 19 02: 59 02 [mask] (DTC_hi DTC_mid FTB status)*
    public static func udsDTCs(payload: [UInt8], module: String) -> [DTC] {
        guard payload.count >= 3, payload[0] == 0x59, payload[1] == 0x02 else { return [] }
        let body = Array(payload.dropFirst(3))
        var out: [DTC] = []
        var i = 0
        while i + 3 < body.count {
            out.append(DTC(code: code(body[i], body[i + 1]), failureType: body[i + 2], status: body[i + 3], module: module))
            i += 4
        }
        return out
    }
}
