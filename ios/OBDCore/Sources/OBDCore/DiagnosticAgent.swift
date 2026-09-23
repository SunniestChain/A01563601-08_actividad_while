import Foundation

public enum AgentEvent: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolCall(id: String, name: String, input: String)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    case notice(String)
    case error(String)
    case finished
}

/// Ciclo agéntico manual: Claude pide herramientas, la app las ejecuta contra el
/// ELM327 y devuelve los resultados hasta que Claude termina el turno.
public actor DiagnosticAgent {
    public let client: MessagesAPI
    public let toolbox: AgentToolbox
    public private(set) var messages: [JSONValue] = []
    private var pendingContext: String?
    public var maxSteps = 30

    public init(client: MessagesAPI, toolbox: AgentToolbox) {
        self.client = client
        self.toolbox = toolbox
    }

    public func reset() {
        messages = []
        pendingContext = nil
    }

    /// Datos de la conexión actual; se adjuntan al siguiente mensaje del usuario
    /// (no al system prompt, para no romper la caché del prefijo).
    public func setConnectionContext(_ text: String) {
        pendingContext = text
    }

    public var systemPrompt: String {
        SystemPrompt.build(catalog: toolbox.database.compactCatalog())
    }

    public func run(_ userText: String, emit: @Sendable (AgentEvent) -> Void) async {
        var content: [JSONValue] = []
        if let ctx = pendingContext {
            content.append(["type": "text", "text": .string("<conexion>\n\(ctx)\n</conexion>")])
            pendingContext = nil
        }
        content.append(["type": "text", "text": .string(userText)])
        messages.append(["role": "user", "content": .array(content)])

        let system = systemPrompt
        let tools = toolbox.definitions

        for _ in 0..<maxSteps {
            if Task.isCancelled { emit(.notice("Cancelado.")); break }
            let response: ClaudeResponse
            do {
                response = try await client.send(system: system, tools: tools, messages: messages)
            } catch {
                emit(.error("\(error)"))
                // El último mensaje del usuario se queda; el usuario puede reintentar.
                break
            }

            // Se reenvía el contenido completo (thinking, tool_use, fallback...) sin tocar.
            messages.append(["role": "assistant", "content": .array(response.content)])

            var toolUses: [(id: String, name: String, input: JSONValue)] = []
            for block in response.content {
                switch block["type"]?.stringValue {
                case "text":
                    if let t = block["text"]?.stringValue, !t.isEmpty { emit(.text(t)) }
                case "thinking":
                    if let t = block["thinking"]?.stringValue, !t.isEmpty { emit(.thinking(t)) }
                case "fallback":
                    let to = block["to"]?["model"]?.stringValue ?? "?"
                    emit(.notice("La petición se atendió con \(to) (fallback de seguridad)."))
                case "tool_use":
                    let id = block["id"]?.stringValue ?? ""
                    let name = block["name"]?.stringValue ?? ""
                    let input = block["input"] ?? [:]
                    toolUses.append((id, name, input))
                default:
                    break
                }
            }

            switch response.stopReason {
            case "tool_use":
                var results: [JSONValue] = []
                for call in toolUses {
                    emit(.toolCall(id: call.id, name: call.name, input: call.input.jsonString()))
                    let r: AgentToolbox.Result
                    if Task.isCancelled {
                        r = .init(text: "cancelado por el usuario", isError: true)
                    } else {
                        r = await toolbox.execute(name: call.name, input: call.input)
                    }
                    emit(.toolResult(id: call.id, name: call.name, output: r.text, isError: r.isError))
                    var block: [String: JSONValue] = [
                        "type": "tool_result",
                        "tool_use_id": .string(call.id),
                        "content": .string(r.text),
                    ]
                    if r.isError { block["is_error"] = true }
                    results.append(.object(block))
                }
                // Todos los resultados en un solo mensaje de usuario.
                messages.append(["role": "user", "content": .array(results)])
                continue
            case "refusal":
                emit(.error("Claude declinó la petición."))
            case "max_tokens":
                emit(.notice("La respuesta se cortó por longitud; pide que continúe."))
            default:
                break
            }
            emit(.finished)
            return
        }
        emit(.finished)
    }
}

public enum SystemPrompt {
    public static func build(catalog: String) -> String {
        """
        Eres el ingeniero de diagnóstico dentro de RangerLink, una app de iPhone conectada por un adaptador ELM327 al puerto OBD-II de una Ford Ranger PX (T6) con motor 3.2 L Duratorq TDCi de 5 cilindros (diésel common rail, turbo de geometría variable, EGR y, según año, DPF). Transmisión 6R80 automática o MT82 manual. Hablas español de México, directo y sin relleno.

        Tienes herramientas que ejecutan lecturas reales en la camioneta. Tu trabajo es convertir la pregunta del usuario en un plan de mediciones, ejecutarlo, e interpretar los datos crudos con criterio de mecánico diésel.

        Cómo trabajar:
        - Empieza con vehicle_info si aún no sabes qué soporta la PCM. No asumas que un PID responde: compruébalo.
        - Elige pocas señales por muestreo (el enlace ELM327 es lento: ~10-25 lecturas/s en total). Para dinámica usa sample_pids con 1-6 señales; para una foto usa read_pids.
        - Si una prueba requiere una condición (motor caliente, rpm sostenidas, A/C encendido), pídela con ask_driver antes de medir. Nunca pidas maniobras en vía pública; las pruebas en movimiento requieren que un acompañante opere el teléfono.
        - Cada PID tiene un nivel de confianza: sae-standard (norma), confirmed-ranger (reportado funcionando en PX/BT-50/Everest 3.2), ford-diesel-sibling (probado en Transit u otro diésel Ford), ford-generic (sin verificar en esta camioneta). Dilo cuando una conclusión dependa de un DID no confirmado, y valida su plausibilidad (rango físico, correlación con PIDs estándar) antes de confiar en él.
        - Puedes explorar DIDs no catalogados con read_did y scan_dids y cruzarlos con señales conocidas (p. ej. un DID que sigue a las RPM o a la presión del riel). Reporta hallazgos como hipótesis, no como hechos.
        - Todo es de sólo lectura. No intentes escribir, programar, ejecutar rutinas ni borrar códigos salvo que el usuario lo pida explícitamente; send_raw bloquea o pide confirmación de todos modos.

        Criterios del 3.2 TDCi (orientativos, verifícalos contra los datos):
        - Ralentí caliente ~750-800 rpm estable (variación > ±25 rpm sugiere desbalance de inyección, fugas de retorno, o aire en combustible).
        - Presión de riel: ~250-400 bar en ralentí, >1000 bar a carga; la real debe seguir a la deseada (desviaciones sostenidas > 50 bar = regulación, bomba, filtro o fugas de inyector).
        - Correcciones/balance por cilindro: los valores deben ser parecidos entre cilindros; un cilindro que pide notablemente más (o menos) caudal que los demás es el sospechoso. Confirma con prueba de retorno de inyectores (física) antes de condenar un inyector.
        - Boost: la presión real debe seguir a la comandada; error sostenido = VGT pegado, fuga de admisión, o EGR abierta de más.
        - DPF: presión diferencial alta con poco flujo de aire = filtro cargado; sin DPF (modelos tempranos) esos PIDs no responden.

        Formato de respuesta: primero la conclusión y qué tan seguro estás; luego los números que la sustentan (con unidades); luego el siguiente paso concreto (medición adicional o revisión física). Si los datos no alcanzan para concluir, dilo y propone la medición que falta.

        Catálogo de señales disponibles (id | módulo cabeceras comando | nombre [unidad rango] | confianza):
        \(catalog)
        """
    }
}
