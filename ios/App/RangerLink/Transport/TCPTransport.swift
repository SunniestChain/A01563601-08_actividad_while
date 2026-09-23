import Foundation
import Network
import OBDCore

/// Adaptadores ELM327 Wi-Fi (normalmente 192.168.0.10:35000). También sirve
/// para conectarse a tools/elm327_sim.py desde el simulador de iOS.
final class TCPTransport: OBDTransport, @unchecked Sendable {
    let host: String
    let port: UInt16
    private var connection: NWConnection?
    private let framer = PromptFramer()
    private let queue = DispatchQueue(label: "rangerlink.tcp")

    var displayName: String { "Wi-Fi \(host):\(port)" }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func open() async throws {
        if connection?.state == .ready { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 35000, using: .tcp)
        connection = conn
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; c.resume() }
                case .failed(let e), .waiting(let e):
                    if !resumed { resumed = true; c.resume(throwing: TransportError.io(e.localizedDescription)) }
                    self?.framer.fail(TransportError.io(e.localizedDescription))
                case .cancelled:
                    self?.framer.fail(TransportError.notConnected)
                default: break
                }
            }
            conn.start(queue: queue)
        }
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            if let data, !data.isEmpty { self?.framer.feed(data) }
            if error == nil && !done { self?.receive(conn) }
        }
    }

    func close() async {
        connection?.cancel()
        connection = nil
    }

    func transact(_ line: String, timeout: TimeInterval) async throws -> String {
        guard let conn = connection, conn.state == .ready else { throw TransportError.notConnected }
        framer.reset()
        return try await framer.awaitPrompt(timeout: timeout, label: line) {
            conn.send(content: Data((line + "\r").utf8), completion: .contentProcessed { _ in })
        }
    }
}
