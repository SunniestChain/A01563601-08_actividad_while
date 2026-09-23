import Foundation

/// Enlace de bajo nivel con el adaptador (BLE, Wi-Fi TCP o simulador).
/// Una transacción = mandar una línea y leer hasta el prompt '>' del ELM327.
public protocol OBDTransport: AnyObject, Sendable {
    var displayName: String { get }
    func open() async throws
    func close() async
    func transact(_ line: String, timeout: TimeInterval) async throws -> String
}

public enum TransportError: Error, CustomStringConvertible, Equatable {
    case notConnected
    case timeout(String)
    case io(String)

    public var description: String {
        switch self {
        case .notConnected: return "adaptador no conectado"
        case .timeout(let c): return "sin respuesta del adaptador a '\(c)'"
        case .io(let s): return "error de comunicación: \(s)"
        }
    }
}

/// Acumula bytes entrantes y entrega todo lo recibido cuando aparece '>'.
/// Lo comparten los transportes BLE y TCP.
public final class PromptFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var waiter: CheckedContinuation<String, Error>?

    public init() {}

    public func reset() {
        lock.lock(); buffer = ""; lock.unlock()
    }

    public func feed(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        buffer += text
        guard let idx = buffer.firstIndex(of: ">"), let w = waiter else { lock.unlock(); return }
        let chunk = String(buffer[..<idx])
        buffer = String(buffer[buffer.index(after: idx)...])
        waiter = nil
        lock.unlock()
        w.resume(returning: chunk)
    }

    /// Espera el siguiente prompt. `send` se invoca después de registrar la espera.
    public func awaitPrompt(timeout: TimeInterval, label: String, send: @escaping @Sendable () throws -> Void) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                    self.lock.lock()
                    if let idx = self.buffer.firstIndex(of: ">") {
                        let chunk = String(self.buffer[..<idx])
                        self.buffer = String(self.buffer[self.buffer.index(after: idx)...])
                        self.lock.unlock()
                        c.resume(returning: chunk)
                        return
                    }
                    self.waiter = c
                    self.lock.unlock()
                    do { try send() } catch { self.fail(error) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fail(TransportError.timeout(label))
                throw TransportError.timeout(label)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TransportError.timeout(label) }
            return first
        }
    }

    public func fail(_ error: Error) {
        lock.lock()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: error)
    }
}
