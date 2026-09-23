import Foundation

/// Lo que la UI debe proveer para que Claude pueda pedirle cosas al conductor.
public protocol DriverInteraction: Sendable {
    /// Muestra una instrucción ("acelera a 2000 rpm y mantén") y espera
    /// "Listo" (true) o "Cancelar" (false).
    func ask(_ instruction: String) async -> Bool
    /// Pide aprobar un comando sensible (borrar DTCs, sesión extendida).
    func confirm(_ command: String, reason: String) async -> Bool
}

/// Herramientas que Claude puede ejecutar contra la camioneta. Todo es de lectura;
/// lo sensible pasa por confirmación del usuario y SafetyGuard.
public final class AgentToolbox: @unchecked Sendable {
    public let elm: ELM327
    public let database: PIDDatabase
    public let driver: DriverInteraction

    public init(elm: ELM327, database: PIDDatabase, driver: DriverInteraction) {
        self.elm = elm
        self.database = database
        self.driver = driver
    }

    static let maxPIDsPerRead = 24
    static let maxSampleSeconds = 180.0
    static let maxScanSpan = 256

    public var definitions: [JSONValue] {
        [
            tool("vehicle_info",
                 "Información de la conexión: adaptador, protocolo, voltaje de batería (ATRV), VIN y la lista de PIDs de modo 01 que la PCM dice soportar. Úsala al inicio para saber qué se puede leer.",
                 [:], []),
            tool("search_pids",
                 "Busca en la base de PIDs local (estándar SAE + DIDs Ford Modo 22 recopilados de la comunidad) y devuelve detalle completo: módulo, cabeceras, fórmula, rango, nivel de confianza, fuentes y notas.",
                 ["query": ["type": "string", "description": "Texto a buscar: id, nombre, categoría (fuel, turbo, dpf, egr, injectors...) o módulo."]],
                 ["query"]),
            tool("read_pids",
                 "Lee una vez (snapshot) uno o más PIDs de la base por id. Devuelve valor decodificado, unidad y respuesta cruda en hex.",
                 ["pid_ids": ["type": "array", "items": ["type": "string"], "description": "Ids de la base, p. ej. [\"OBD.01.0C\", \"OBD.01.23\"]. Máximo 24."]],
                 ["pid_ids"]),
            tool("sample_pids",
                 "Registra PIDs en vivo durante un tiempo y devuelve estadísticas (min, max, media, desviación) y una serie reducida por señal. Úsala para diagnosticar comportamientos (fluctuaciones, respuesta a aceleración, deriva). Pocas señales = mayor frecuencia de muestreo.",
                 [
                    "pid_ids": ["type": "array", "items": ["type": "string"], "description": "Ids de la base. Idealmente 1-6 para buena resolución."],
                    "duration_s": ["type": "number", "description": "Duración en segundos (máximo 180)."],
                    "interval_ms": ["type": "integer", "description": "Intervalo objetivo entre barridos en ms (0 = lo más rápido posible)."],
                 ],
                 ["pid_ids", "duration_s", "interval_ms"]),
            tool("read_did",
                 "Lee un DID arbitrario con UDS servicio 22 en un módulo, aunque no esté en la base. Devuelve el payload crudo. Útil para explorar DIDs propietarios de Ford y cruzarlos con valores conocidos.",
                 [
                    "module": ["type": "string", "description": "Nombre del módulo (PCM, TCM, ABS, PSCM, RCM, IPC, BCM) o cabecera de petición en hex (p. ej. 7E0)."],
                    "did": ["type": "string", "description": "DID de 4 dígitos hex, p. ej. F40C o 1310."],
                 ],
                 ["module", "did"]),
            tool("scan_dids",
                 "Barre un rango de DIDs (servicio 22) en un módulo y reporta cuáles responden positivo, con su payload crudo. Máximo 256 DIDs por llamada; tarda ~30-80 ms por DID.",
                 [
                    "module": ["type": "string", "description": "Nombre del módulo o cabecera de petición."],
                    "start_did": ["type": "string", "description": "DID inicial hex (4 dígitos)."],
                    "end_did": ["type": "string", "description": "DID final hex (4 dígitos), inclusivo."],
                 ],
                 ["module", "start_did", "end_did"]),
            tool("read_dtcs",
                 "Lee códigos de falla: OBD genéricos (almacenados, pendientes, permanentes) y, si se indican, DTCs UDS completos (con tipo de falla y estado) de módulos Ford. No borra nada.",
                 ["modules": ["type": "array", "items": ["type": "string"], "description": "Módulos para leer por UDS 19 02 (p. ej. [\"PCM\", \"TCM\", \"ABS\"]). Lista vacía = sólo OBD genérico."]],
                 ["modules"]),
            tool("send_raw",
                 "Envía un comando crudo al ELM327 (AT o hex OBD/UDS) opcionalmente a un módulo. Filtrado por seguridad: sólo servicios de lectura; borrar DTCs o sesión extendida piden aprobación al usuario; escritura, rutinas, reset y seguridad están bloqueados.",
                 [
                    "command": ["type": "string", "description": "Comando, p. ej. \"ATRV\", \"0105\", \"22 F4 0C\"."],
                    "module": ["type": "string", "description": "Módulo o cabecera; cadena vacía = no cambiar cabecera."],
                 ],
                 ["command", "module"]),
            tool("ask_driver",
                 "Muestra una instrucción al usuario y espera a que confirme (p. ej. 'Con el motor caliente y en P, mantén 2000 rpm y toca Listo'). Úsala antes de un muestreo que requiera una condición. Nunca pidas maniobras en vía pública sin un acompañante que opere el teléfono.",
                 ["instruction": ["type": "string", "description": "Instrucción clara y corta en español."]],
                 ["instruction"]),
        ]
    }

    private func tool(_ name: String, _ description: String, _ props: [String: JSONValue], _ required: [String]) -> JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": [
                "type": "object",
                "properties": .object(props),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ],
        ]
    }

    // MARK: - Ejecución

    public struct Result: Sendable {
        public let text: String
        public let isError: Bool
    }

    public func execute(name: String, input: JSONValue) async -> Result {
        do {
            let out = try await run(name: name, input: input)
            return Result(text: out.jsonString(), isError: false)
        } catch {
            return Result(text: "\(error)", isError: true)
        }
    }

    struct InputError: Error, CustomStringConvertible {
        let description: String
    }

    private func string(_ input: JSONValue, _ key: String) throws -> String {
        guard let s = input[key]?.stringValue else { throw InputError(description: "falta '\(key)'") }
        return s
    }

    private func module(_ s: String) throws -> (tx: String, rx: String?, name: String) {
        if let m = FordModules.named(s) { return (m.tx, m.rx, m.name) }
        let h = s.uppercased()
        guard h.count == 3, h.allSatisfy(\.isHexDigit), let v = Int(h, radix: 16) else {
            throw InputError(description: "módulo desconocido '\(s)'")
        }
        // Convención Ford/ISO 15765: la respuesta llega en cabecera + 8.
        return (h, String(format: "%03X", v + 8), h)
    }

    private func pids(_ input: JSONValue) throws -> [PIDDefinition] {
        let ids = (input["pid_ids"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !ids.isEmpty else { throw InputError(description: "pid_ids vacío") }
        guard ids.count <= Self.maxPIDsPerRead else { throw InputError(description: "máximo \(Self.maxPIDsPerRead) PIDs") }
        let unknown = ids.filter { database[$0] == nil }
        guard unknown.isEmpty else {
            throw InputError(description: "ids desconocidos: \(unknown.joined(separator: ", ")). Usa search_pids.")
        }
        return ids.compactMap { database[$0] }
    }

    private func run(name: String, input: JSONValue) async throws -> JSONValue {
        switch name {
        case "vehicle_info":
            let supported = (try? await elm.supportedMode01())?.sorted() ?? []
            return [
                "adapter": .string(await elm.adapterID),
                "protocol": .string(await elm.protocolName),
                "transport": .string(elm.transport.displayName),
                "battery": .string(await elm.batteryVoltage() ?? "?"),
                "vin": .string(await elm.vin() ?? "no disponible"),
                "mode01_supported": .array(supported.map { .string($0) }),
                "database_ids_supported": .array(database.pids
                    .filter { $0.service == "01" && supported.contains($0.pid) }
                    .map { .string($0.id) }),
            ]

        case "search_pids":
            let hits = database.search(try string(input, "query")).prefix(40)
            return .array(try hits.map { try JSONValue.from($0) })

        case "read_pids":
            let readings = await elm.read(try pids(input))
            return .array(readings.map { r in
                var o: [String: JSONValue] = ["id": .string(r.id), "name": .string(r.name), "unit": .string(r.unit)]
                if let v = r.value { o["value"] = .double((v * 1000).rounded() / 1000) }
                if let raw = r.raw { o["raw"] = .string(raw) }
                if let e = r.error { o["error"] = .string(e) }
                return .object(o)
            })

        case "sample_pids":
            let list = try pids(input)
            let duration = min(max(input["duration_s"]?.doubleValue ?? 10, 1), Self.maxSampleSeconds)
            let interval = max(input["interval_ms"]?.doubleValue ?? 0, 0) / 1000
            let stats = await elm.sample(list, duration: duration, interval: interval)
            return ["duration_s": .double(duration), "signals": try JSONValue.from(stats)]

        case "read_did":
            let m = try module(try string(input, "module"))
            let did = try string(input, "did").uppercased().filter(\.isHexDigit)
            guard did.count == 4 else { throw InputError(description: "el DID debe tener 4 dígitos hex") }
            let r = try await elm.request(tx: m.tx, rx: m.rx, command: "22" + did)
            return describe(r, module: m.name)

        case "scan_dids":
            let m = try module(try string(input, "module"))
            guard let a = Int(try string(input, "start_did"), radix: 16),
                  let b = Int(try string(input, "end_did"), radix: 16), a <= b, b <= 0xFFFF else {
                throw InputError(description: "rango de DIDs inválido")
            }
            guard b - a < Self.maxScanSpan else { throw InputError(description: "máximo \(Self.maxScanSpan) DIDs por barrido") }
            var found: [JSONValue] = []
            var negatives: [String: Int] = [:]
            for did in a...b {
                if Task.isCancelled { break }
                let hex = String(format: "%04X", did)
                guard let r = try? await elm.request(tx: m.tx, rx: m.rx, command: "22" + hex) else { continue }
                if let msg = r.messages.first(where: { $0.payload.first == 0x62 }) {
                    found.append(["did": .string(hex), "data": .string(Hex.string(Array(msg.payload.dropFirst(3))))])
                } else if let c = r.messages.first(where: \.isNegative)?.negativeCode {
                    negatives[ELMResponseParser.nrcName(c), default: 0] += 1
                } else {
                    negatives[r.status.rawValue, default: 0] += 1
                }
            }
            return [
                "module": .string(m.name),
                "range": .string(String(format: "%04X-%04X", a, b)),
                "positive": .array(found),
                "other_responses": .object(negatives.mapValues { .int($0) }),
            ]

        case "read_dtcs":
            var out: [String: JSONValue] = [:]
            let obd = await elm.obdDTCs()
            out["obd"] = .object(obd.mapValues { list in .array(list.map { .string("\($0.displayCode) (\($0.module))") }) })
            var uds: [String: JSONValue] = [:]
            for name in (input["modules"]?.arrayValue ?? []).compactMap(\.stringValue) {
                do {
                    let m = try module(name)
                    let list = try await elm.udsDTCs(tx: m.tx, rx: m.rx ?? "", module: m.name)
                    uds[m.name] = .array(list.map { .string("\($0.displayCode) [\($0.statusText ?? "")]") })
                } catch {
                    uds[name] = .string("error: \(error)")
                }
            }
            out["uds"] = .object(uds)
            return .object(out)

        case "send_raw":
            let cmd = try string(input, "command")
            let modName = input["module"]?.stringValue ?? ""
            var confirmed = false
            if case .needsConfirmation(let why) = SafetyGuard.check(cmd) {
                confirmed = await driver.confirm(cmd, reason: why)
                guard confirmed else { throw InputError(description: "el usuario rechazó el comando \(cmd)") }
            }
            let r: ELMResponse
            if modName.isEmpty {
                r = try await elm.send(cmd, confirmed: confirmed)
            } else {
                let m = try module(modName)
                r = try await elm.request(tx: m.tx, rx: m.rx, command: cmd, confirmed: confirmed)
            }
            return describe(r, module: modName)

        case "ask_driver":
            let ok = await driver.ask(try string(input, "instruction"))
            return ["confirmed": .bool(ok)]

        default:
            throw InputError(description: "herramienta desconocida \(name)")
        }
    }

    private func describe(_ r: ELMResponse, module: String) -> JSONValue {
        [
            "module": .string(module),
            "status": .string(r.status.rawValue),
            "lines": .array(r.lines.map { .string($0) }),
            "messages": .array(r.messages.map { m in
                var o: [String: JSONValue] = ["header": .string(m.header), "payload": .string(Hex.string(m.payload))]
                if let c = m.negativeCode { o["negative"] = .string(ELMResponseParser.nrcName(c)) }
                return .object(o)
            }),
        ]
    }
}
