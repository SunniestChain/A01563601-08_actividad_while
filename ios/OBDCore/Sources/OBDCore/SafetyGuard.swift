import Foundation

/// Filtro de comandos. Todo lo que manda la app, y sobre todo lo que pide Claude,
/// pasa por aquí. La regla: leer sí, escribir/programar/actuar no.
public enum SafetyVerdict: Equatable, Sendable {
    case allowed
    /// Sólo si el usuario lo aprueba en pantalla (borrar DTCs, sesión extendida).
    case needsConfirmation(String)
    case blocked(String)
}

public enum SafetyGuard {
    /// Comandos AT inofensivos (configuración de la sesión del adaptador, lecturas).
    static let atAllow = [
        "ATZ", "ATWS", "ATD", "ATI", "AT@1", "ATRV", "ATDP", "ATDPN",
        "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATSP", "ATTP", "ATSH", "ATCRA", "ATAR", "ATCAF", "ATAT", "ATST",
        "ATFCSH", "ATFCSD", "ATFCSM", "ATCFC", "ATCM", "ATCF",
        "STI", "STDI", "STP", "STPBR", // OBDLink (STN) lecturas/protocolo
    ]

    /// Comandos AT que se bloquean aunque empiecen igual que uno permitido.
    static let atDeny = [
        "ATPP",   // escribe parámetros programables en la EEPROM del adaptador
        "ATBRD",  // cambia el baud rate: deja el adaptador inaccesible
        "ATBRT", "ATLP", "ATMA", "ATMR", "ATMT", // monitores: inundan el enlace
        "ATSW", "ATSI", "ATFI", "ATKW",
        "ATSTWR", "STWBR", "STSBR",
    ]

    /// Servicios OBD/UDS de sólo lectura.
    static let readServices: Set<UInt8> = [0x01, 0x02, 0x03, 0x06, 0x07, 0x09, 0x0A, 0x19, 0x22]

    public static func normalize(_ command: String) -> String {
        command.uppercased().filter { !$0.isWhitespace }
    }

    public static func check(_ command: String) -> SafetyVerdict {
        let c = normalize(command)
        guard !c.isEmpty else { return .blocked("comando vacío") }

        if c.hasPrefix("AT") || c.hasPrefix("ST") {
            if let d = atDeny.first(where: { c.hasPrefix($0) }) {
                return .blocked("\(d) está bloqueado (modifica o satura el adaptador)")
            }
            if atAllow.contains(where: { c.hasPrefix($0) }) { return .allowed }
            return .blocked("comando AT no está en la lista permitida")
        }

        guard c.count % 2 == 0, c.allSatisfy(\.isHexDigit) else {
            return .blocked("no es hex válido")
        }
        let bytes = Hex.bytes(c)
        guard let sid = bytes.first else { return .blocked("vacío") }

        if readServices.contains(sid) { return .allowed }
        switch sid {
        case 0x3E:
            return bytes.count <= 2 ? .allowed : .blocked("TesterPresent mal formado")
        case 0x10:
            let sub = bytes.count > 1 ? bytes[1] : 0
            if sub == 0x01 { return .allowed }
            if sub == 0x03 { return .needsConfirmation("Abrir sesión de diagnóstico extendida (10 03) en el módulo") }
            return .blocked("sólo se permite la sesión por defecto (10 01) o extendida (10 03)")
        case 0x04:
            return .needsConfirmation("Borrar códigos OBD (servicio 04). Apaga el testigo y reinicia monitores de emisiones.")
        case 0x14:
            return .needsConfirmation("Borrar DTCs del módulo (UDS 14)")
        case 0x11: return .blocked("ECUReset (11) bloqueado")
        case 0x27: return .blocked("SecurityAccess (27) bloqueado")
        case 0x28: return .blocked("CommunicationControl (28) bloqueado")
        case 0x2E: return .blocked("WriteDataByIdentifier (2E) bloqueado")
        case 0x2F: return .blocked("InputOutputControl (2F) bloqueado: actúa componentes")
        case 0x31: return .blocked("RoutineControl (31) bloqueado: pruebas/rutinas activas")
        case 0x34, 0x35, 0x36, 0x37: return .blocked("transferencia/programación bloqueada")
        case 0x08: return .blocked("control de sistemas a bordo (08) bloqueado")
        case 0x23, 0x3D: return .blocked("acceso a memoria por dirección bloqueado")
        case 0x85: return .blocked("ControlDTCSetting (85) bloqueado")
        default: return .blocked(String(format: "servicio 0x%02X no está permitido", sid))
        }
    }
}
