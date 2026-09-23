import Foundation

public struct VehicleModule: Sendable, Equatable, Codable {
    public let name: String
    public let tx: String
    public let rx: String
    public let bus: String
    public let description: String
}

/// Módulos conocidos de la Ranger PX/PX2/PX3. Los de MS-CAN (pines 3/11) sólo
/// responden con un adaptador que conmute de bus (p. ej. OBDLink MX+/CX o un
/// ELM327 "modificado" con switch HS/MS); con un ELM327 genérico darán NO DATA.
public enum FordModules {
    public static let rangerPX: [VehicleModule] = [
        VehicleModule(name: "PCM", tx: "7E0", rx: "7E8", bus: "HS-CAN", description: "Motor 3.2 TDCi"),
        VehicleModule(name: "TCM", tx: "7E1", rx: "7E9", bus: "HS-CAN", description: "Transmisión 6R80"),
        VehicleModule(name: "BCM", tx: "726", rx: "72E", bus: "HS-CAN", description: "Carrocería / TPMS (PX2/PX3)"),
        // Sin confirmar en PX: en los logs de OBDb no respondieron 720/760 con ELM327 genérico.
        VehicleModule(name: "ABS", tx: "760", rx: "768", bus: "¿HS-CAN?", description: "Frenos / ESC (sin confirmar)"),
        VehicleModule(name: "IPC", tx: "720", rx: "728", bus: "¿HS/MS-CAN?", description: "Tablero (sin confirmar)"),
        VehicleModule(name: "PSCM", tx: "730", rx: "738", bus: "¿HS-CAN?", description: "Dirección eléctrica (sin confirmar)"),
        VehicleModule(name: "RCM", tx: "737", rx: "73F", bus: "¿HS-CAN?", description: "Bolsas de aire (sin confirmar)"),
    ]

    public static func named(_ name: String) -> VehicleModule? {
        rangerPX.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.tx == name.uppercased() }
    }
}
