import CoreBluetooth
import Foundation
import Observation
import OBDCore

/// Adaptadores ELM327 Bluetooth LE. iOS no permite Bluetooth clásico (SPP) sin
/// certificación MFi, así que los ELM327 "Bluetooth 2.0" baratos NO sirven en
/// iPhone: se necesita uno BLE (Vgate iCar Pro BLE, OBDLink CX/MX+, Veepeak BLE...).
@Observable
final class BLETransport: NSObject, OBDTransport, @unchecked Sendable {
    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    private(set) var devices: [Device] = []
    private(set) var state = "Apagado"
    private(set) var isScanning = false
    private(set) var connectedName: String?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var notifyChar: CBCharacteristic?
    @ObservationIgnored private var readyWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var targetID: UUID?
    @ObservationIgnored private let framer = PromptFramer()

    /// Pares (servicio, notify, write) conocidos de adaptadores ELM327 BLE.
    private static let knownServices: [CBUUID] = ["FFF0", "FFE0", "18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"].map { CBUUID(string: $0) }

    var displayName: String { "BLE \(connectedName ?? "?")" }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else { state = "Bluetooth no disponible"; return }
        devices = []
        isScanning = true
        // Sin filtro de servicios: muchos clones no anuncian su UUID.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func select(_ id: UUID) { targetID = id }

    func open() async throws {
        if writeChar != nil, notifyChar != nil, peripheral?.state == .connected { return }
        guard let id = targetID, let p = peripherals[id] else { throw TransportError.io("elige un adaptador BLE") }
        stopScan()
        peripheral = p
        p.delegate = self
        state = "Conectando..."
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyWaiter = c
            central.connect(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finishOpen(TransportError.timeout("conexión BLE"))
            }
        }
    }

    private func finishOpen(_ error: Error?) {
        guard let w = readyWaiter else { return }
        readyWaiter = nil
        if let error { w.resume(throwing: error) } else { w.resume() }
    }

    func close() async {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        connectedName = nil
    }

    func transact(_ line: String, timeout: TimeInterval) async throws -> String {
        guard let p = peripheral, let w = writeChar else { throw TransportError.notConnected }
        framer.reset()
        let data = Data((line + "\r").utf8)
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        return try await framer.awaitPrompt(timeout: timeout, label: line) {
            DispatchQueue.main.async {
                var offset = 0
                while offset < data.count {
                    let chunk = data.subdata(in: offset..<min(offset + mtu, data.count))
                    p.writeValue(chunk, for: w, type: type)
                    offset += mtu
                }
            }
        }
    }
}

extension BLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = "Listo"
        case .unauthorized: state = "Sin permiso de Bluetooth (Ajustes > RangerLink)"
        case .poweredOff: state = "Bluetooth apagado"
        default: state = "Bluetooth no disponible"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard !name.isEmpty else { return }
        peripherals[peripheral.identifier] = peripheral
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[i].rssi = RSSI.intValue
        } else {
            devices.append(Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            // Los que parecen OBD primero.
            devices.sort { a, b in
                let ka = Self.looksLikeOBD(a.name), kb = Self.looksLikeOBD(b.name)
                return ka != kb ? ka : a.rssi > b.rssi
            }
        }
    }

    static func looksLikeOBD(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["OBD", "ELM", "VGATE", "VLINK", "ICAR", "VEEPEAK", "KONNWEI", "CARLY"].contains { n.contains($0) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = "Descubriendo servicios..."
        connectedName = peripheral.name
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = "No se pudo conectar"
        finishOpen(TransportError.io(error?.localizedDescription ?? "falló la conexión"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = "Desconectado"
        writeChar = nil
        notifyChar = nil
        framer.fail(TransportError.notConnected)
        finishOpen(TransportError.notConnected)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let ordered = services.filter { Self.knownServices.contains($0.uuid) } + services.filter { !Self.knownServices.contains($0.uuid) }
        for s in ordered { peripheral.discoverCharacteristics(nil, for: s) }
        if services.isEmpty { finishOpen(TransportError.io("el adaptador no expone servicios")) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard writeChar == nil || notifyChar == nil else { return }
        let chars = service.characteristics ?? []
        let notify = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        let write = chars.first { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }
        // Sólo aceptamos un servicio que tenga ambos (evita elegir "Device Information").
        guard let notify, let write else { return }
        notifyChar = notify
        writeChar = write
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finishOpen(TransportError.io(error.localizedDescription))
        } else if characteristic == notifyChar {
            state = "Conectado"
            finishOpen(nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let v = characteristic.value { framer.feed(v) }
    }
}
