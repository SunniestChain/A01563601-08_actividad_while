import Foundation

/// Mensaje UDS ya reensamblado (ISO-TP) de una ECU.
public struct ECUMessage: Sendable, Equatable {
    public let header: String      // p. ej. "7E8"
    public let payload: [UInt8]    // sin PCI: 41 0C 1A F8 / 62 F4 0C ...

    public var isNegative: Bool { payload.first == 0x7F }
    /// Código NRC si es respuesta negativa (7F SID NRC).
    public var negativeCode: UInt8? { isNegative && payload.count >= 3 ? payload[2] : nil }
    /// 0x78 = "response pending": la ECU sigue procesando.
    public var isResponsePending: Bool { negativeCode == 0x78 }
}

public enum ELMStatus: String, Sendable, Equatable {
    case ok, noData = "NO DATA", error = "ERROR", unableToConnect = "UNABLE TO CONNECT"
    case canError = "CAN ERROR", busInit = "BUS INIT", stopped = "STOPPED", bufferFull = "BUFFER FULL"
    case unknownCommand = "?"
}

public struct ELMResponse: Sendable, Equatable {
    public let raw: String
    public let lines: [String]
    public let messages: [ECUMessage]
    public let status: ELMStatus

    public var firstPositive: ECUMessage? { messages.first { !$0.isNegative } }
}

/// Parser de respuestas del ELM327 configurado con ATH1 (cabeceras), ATS1 (espacios)
/// y ATCAF1 (formateo CAN): cada línea es "7E8 06 41 0C 1A F8 00 00" (cabecera,
/// PCI, datos). Reensambla multi-frame ISO-TP (10 xx / 21 / 22...).
public enum ELMResponseParser {
    static let statusMarkers: [ELMStatus] = [.noData, .unableToConnect, .canError, .busInit, .stopped, .bufferFull, .error]

    public static func parse(_ raw: String) -> ELMResponse {
        let lines = raw
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != ">" && !$0.hasPrefix("SEARCHING") }
            .map { $0.hasSuffix(">") ? String($0.dropLast()).trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }

        var status = ELMStatus.ok
        for l in lines {
            let up = l.uppercased()
            if up == "?" { status = .unknownCommand }
            if let s = statusMarkers.first(where: { up.contains($0.rawValue) }) { status = s }
        }

        var buffers: [String: (expected: Int, data: [UInt8])] = [:]
        var order: [String] = []
        var done: [ECUMessage] = []

        for l in lines {
            let parts = l.split(separator: " ").map(String.init)
            guard parts.count >= 2,
                  parts[0].count == 3 || parts[0].count == 8,
                  parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) })
            else { continue }
            let header = parts[0].uppercased()
            let bytes = parts.dropFirst().compactMap { UInt8($0, radix: 16) }
            guard let pci = bytes.first else { continue }
            switch pci >> 4 {
            case 0x0: // single frame
                let len = Int(pci & 0x0F)
                let data = Array(bytes.dropFirst().prefix(len))
                done.append(ECUMessage(header: header, payload: data))
            case 0x1: // first frame
                guard bytes.count >= 2 else { continue }
                let len = Int(pci & 0x0F) << 8 | Int(bytes[1])
                buffers[header] = (len, Array(bytes.dropFirst(2)))
                if !order.contains(header) { order.append(header) }
            case 0x2: // consecutive frame
                guard var b = buffers[header] else { continue }
                b.data.append(contentsOf: bytes.dropFirst())
                buffers[header] = b
            default:
                continue
            }
        }
        for h in order {
            if let b = buffers[h] {
                done.append(ECUMessage(header: h, payload: Array(b.data.prefix(b.expected))))
            }
        }
        return ELMResponse(raw: raw, lines: lines, messages: done, status: status)
    }

    /// Nombres de NRC (ISO 14229) más comunes para explicar respuestas negativas.
    public static func nrcName(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "generalReject"
        case 0x11: return "serviceNotSupported"
        case 0x12: return "subFunctionNotSupported"
        case 0x13: return "incorrectMessageLengthOrInvalidFormat"
        case 0x22: return "conditionsNotCorrect"
        case 0x31: return "requestOutOfRange (DID no existe en este módulo)"
        case 0x33: return "securityAccessDenied"
        case 0x78: return "responsePending"
        case 0x7E: return "subFunctionNotSupportedInActiveSession"
        case 0x7F: return "serviceNotSupportedInActiveSession"
        default: return String(format: "NRC 0x%02X", code)
        }
    }
}
