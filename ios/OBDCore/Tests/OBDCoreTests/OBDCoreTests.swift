import XCTest
@testable import OBDCore

/// Carga los mismos pids/*.json que valida tools/pidtool.py.
func loadDatabase() throws -> PIDDatabase {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("pids")
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try PIDDatabase(jsonData: files.map { try Data(contentsOf: $0) })
}

final class FormulaTests: XCTestCase {
    func testBasics() throws {
        XCTAssertEqual(try Formula("(A*256+B)/4").evaluate([0x1A, 0xF8]), 1726)
        XCTAssertEqual(try Formula("A-40").evaluate([0x7B]), 83)
        XCTAssertEqual(try Formula("-A+1").evaluate([3]), -2)
        XCTAssertEqual(try Formula("s16(A,B)/100").evaluate([0xFF, 0x38]), -2)
        XCTAssertEqual(try Formula("s8(A)").evaluate([0x80]), -128)
        XCTAssertEqual(try Formula("u32(A,B,C,D)/10").evaluate([0x00, 0x1E, 0x84, 0x80]), 200000)
        XCTAssertEqual(try Formula("bit(A,7)").evaluate([0x83]), 1)
        XCTAssertEqual(try Formula("0x10*A").evaluate([2]), 32)
        XCTAssertEqual(try Formula("(D*256+E)/32").byteIndices, [3, 4])
    }

    func testErrors() {
        XCTAssertThrowsError(try Formula("A+"))
        XCTAssertThrowsError(try Formula("foo(A)"))
        XCTAssertThrowsError(try Formula("u16(A)"))
        XCTAssertThrowsError(try Formula("B").evaluate([1]))
        XCTAssertThrowsError(try Formula("A/B").evaluate([1, 0]))
    }

    /// Todos los vectores de prueba de la base deben pasar (mismo criterio que pidtool.py).
    func testDatabaseVectors() throws {
        let db = try loadDatabase()
        XCTAssertGreaterThan(db.pids.count, 40)
        var tested = 0
        for p in db.pids {
            let f = try Formula(p.formula)
            XCTAssertLessThanOrEqual(f.maxByteIndex + 1, p.bytes, p.id)
            guard let t = p.test else { continue }
            let v = try p.decode(payload: Hex.bytes(t.response))
            XCTAssertEqual(v, t.expect, accuracy: max(1e-3, abs(t.expect) * 1e-6), p.id)
            tested += 1
        }
        XCTAssertGreaterThan(tested, 40)
    }
}

final class ParserTests: XCTestCase {
    func testSingleFrame() {
        let r = ELMResponseParser.parse("7E8 04 41 0C 1A F8 \r\r>")
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.messages, [ECUMessage(header: "7E8", payload: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    func testMultiFrameVIN() {
        let raw = """
        SEARCHING...
        7E8 10 14 49 02 01 4D 4E 43
        7E8 21 55 4D 46 46 38 30 44
        7E8 22 57 30 30 30 30 30 30
        """
        let r = ELMResponseParser.parse(raw)
        XCTAssertEqual(r.messages.count, 1)
        let m = r.messages[0]
        XCTAssertEqual(m.payload.count, 0x14)
        XCTAssertEqual(String(decoding: m.payload.dropFirst(3), as: UTF8.self), "MNCUMFF80DW000000")
    }

    func testMultipleECUsAndNegative() {
        let r = ELMResponseParser.parse("7E8 03 7F 22 31\r7E9 04 62 F4 0C 20")
        XCTAssertEqual(r.messages.count, 2)
        XCTAssertEqual(r.messages[0].negativeCode, 0x31)
        XCTAssertEqual(r.firstPositive?.header, "7E9")
    }

    func testStatus() {
        XCTAssertEqual(ELMResponseParser.parse("NO DATA\r\r>").status, .noData)
        XCTAssertEqual(ELMResponseParser.parse("?\r>").status, .unknownCommand)
        XCTAssertEqual(ELMResponseParser.parse("SEARCHING...\rUNABLE TO CONNECT").status, .unableToConnect)
    }
}

final class SafetyTests: XCTestCase {
    func testAllowed() {
        for c in ["ATZ", "ATSH7E0", "AT CRA 7E8", "010C", "22 F4 0C", "1902FF", "0902", "03", "3E00", "1001"] {
            XCTAssertEqual(SafetyGuard.check(c), .allowed, c)
        }
    }

    func testConfirm() {
        for c in ["04", "14FFFFFF", "1003"] {
            guard case .needsConfirmation = SafetyGuard.check(c) else { return XCTFail(c) }
        }
    }

    func testBlocked() {
        for c in ["2EF190AA", "2701", "3101FF00", "1101", "ATPP0CSV23", "ATBRD08", "ATMA", "2F", "34", "1002", "XYZ", "0"] {
            guard case .blocked = SafetyGuard.check(c) else { return XCTFail(c) }
        }
    }
}

final class DTCTests: XCTestCase {
    func testOBD() {
        let d = DTCDecoder.obdDTCs(payload: [0x43, 0x02, 0x04, 0x01, 0xC1, 0x00], module: "7E8")
        XCTAssertEqual(d.map(\.code), ["P0401", "U0100"])
    }

    func testUDS() {
        let d = DTCDecoder.udsDTCs(payload: [0x59, 0x02, 0xFF, 0x04, 0x01, 0x00, 0x2F, 0x22, 0x63, 0x00, 0x08], module: "PCM")
        XCTAssertEqual(d.map(\.displayCode), ["P0401-00", "P2263-00"])
        XCTAssertEqual(d[1].statusText, "confirmado")
    }
}

final class SimulatorTests: XCTestCase {
    func testEndToEnd() async throws {
        let db = try loadDatabase()
        let elm = ELM327(transport: SimulatedELM327(database: db))
        try await elm.initialize()
        let vin = await elm.vin()
        XCTAssertEqual(vin, "MNCUMFF80DW000000")
        let supported = try await elm.supportedMode01()
        XCTAssertTrue(supported.contains("0C"))
        XCTAssertTrue(supported.contains("63"))

        let ids = ["OBD.01.0C", "OBD.01.05", "OBD.01.63", "OBD.01.42"]
        let r = await elm.read(ids.compactMap { db[$0] })
        XCTAssertEqual(r.count, 4)
        let rpm = try XCTUnwrap(r[0].value)
        XCTAssertTrue((700...2600).contains(rpm), "rpm \(rpm)")
        XCTAssertEqual(r[2].value, 470)

        let dtcs = await elm.obdDTCs()
        XCTAssertEqual(dtcs["almacenados"]?.map(\.code), ["P0401"])

        let blocked = try? await elm.send("2EF19000")
        XCTAssertNil(blocked)
    }

    func testToolbox() async throws {
        struct AutoDriver: DriverInteraction {
            func ask(_ instruction: String) async -> Bool { true }
            func confirm(_ command: String, reason: String) async -> Bool { false }
        }
        let db = try loadDatabase()
        let elm = ELM327(transport: SimulatedELM327(database: db))
        try await elm.initialize()
        let tb = AgentToolbox(elm: elm, database: db, driver: AutoDriver())
        XCTAssertEqual(tb.definitions.count, 9)

        let read = await tb.execute(name: "read_pids", input: ["pid_ids": ["OBD.01.63"]])
        XCTAssertFalse(read.isError)
        XCTAssertTrue(read.text.contains("\"value\":470"), read.text)

        let sample = await tb.execute(name: "sample_pids", input: ["pid_ids": ["OBD.01.0C"], "duration_s": 1, "interval_ms": 0])
        XCTAssertFalse(sample.isError, sample.text)

        let unknown = await tb.execute(name: "read_pids", input: ["pid_ids": ["NOPE"]])
        XCTAssertTrue(unknown.isError)

        let clear = await tb.execute(name: "send_raw", input: ["command": "04", "module": ""])
        XCTAssertTrue(clear.isError, "borrar DTCs sin confirmación debe fallar")

        let write = await tb.execute(name: "send_raw", input: ["command": "2E F1 90 00", "module": "PCM"])
        XCTAssertTrue(write.isError)
    }
}

final class AgentTests: XCTestCase {
    /// API falsa: primero pide una herramienta, luego contesta con texto.
    final class ScriptedAPI: MessagesAPI, @unchecked Sendable {
        var calls: [[JSONValue]] = []
        func send(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ClaudeResponse {
            calls.append(messages)
            if calls.count == 1 {
                return ClaudeResponse(raw: [
                    "stop_reason": "tool_use",
                    "content": [
                        ["type": "thinking", "thinking": "leer rpm", "signature": "sig"],
                        ["type": "tool_use", "id": "toolu_1", "name": "read_pids", "input": ["pid_ids": ["OBD.01.0C"]]],
                    ],
                ])
            }
            return ClaudeResponse(raw: ["stop_reason": "end_turn", "content": [["type": "text", "text": "Ralentí estable."]]])
        }
    }

    struct NoDriver: DriverInteraction {
        func ask(_ instruction: String) async -> Bool { false }
        func confirm(_ command: String, reason: String) async -> Bool { false }
    }

    func testLoop() async throws {
        let db = try loadDatabase()
        let elm = ELM327(transport: SimulatedELM327(database: db))
        try await elm.initialize()
        let api = ScriptedAPI()
        let agent = DiagnosticAgent(client: api, toolbox: AgentToolbox(elm: elm, database: db, driver: NoDriver()))
        await agent.setConnectionContext("VIN demo")
        let box = EventBox()
        await agent.run("¿cómo está el ralentí?") { box.append($0) }

        XCTAssertEqual(api.calls.count, 2)
        let msgs = await agent.messages
        XCTAssertEqual(msgs.count, 4) // user, assistant(tool_use), user(tool_result), assistant(text)
        XCTAssertEqual(msgs[2]["content"]?.arrayValue?.first?["type"]?.stringValue, "tool_result")
        // El bloque de thinking se reenvía intacto.
        XCTAssertEqual(msgs[1]["content"]?.arrayValue?.first?["signature"]?.stringValue, "sig")
        XCTAssertTrue(msgs[0].jsonString().contains("<conexion>"))
        XCTAssertTrue(box.events.contains(.text("Ralentí estable.")))
        XCTAssertEqual(box.events.last, .finished)
    }

    func testRequestBody() throws {
        let c = ClaudeClient(config: ClaudeConfig(apiKey: "k"))
        let body = c.buildBody(system: "s", tools: [], messages: [])
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5")
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(body["fallbacks"]?.stringValue, "default")
        let req = try c.makeRequest(body: body)
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let haiku = ClaudeClient(config: ClaudeConfig(apiKey: "k", model: "claude-haiku-4-5"))
        let hb = haiku.buildBody(system: "s", tools: [], messages: [])
        XCTAssertNil(hb["thinking"])
        XCTAssertNil(hb["output_config"])
        XCTAssertNil(hb["fallbacks"])
        XCTAssertThrowsError(try ClaudeClient(config: ClaudeConfig(apiKey: "")).makeRequest(body: body))
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentEvent] = []
    var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func append(_ e: AgentEvent) { lock.lock(); _events.append(e); lock.unlock() }
}
