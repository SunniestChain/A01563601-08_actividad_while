import SwiftUI
import OBDCore

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedBLE: UUID?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Tipo", selection: $model.kind) {
                        ForEach(ConnectionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    switch model.kind {
                    case .ble: Text("Necesitas un ELM327 Bluetooth LE (Vgate iCar Pro BLE, OBDLink CX/MX+, Veepeak BLE). Los ELM327 Bluetooth clásicos no funcionan con iPhone.")
                    case .wifi: Text("Conecta el iPhone a la red Wi-Fi del adaptador. También sirve para tools/elm327_sim.py.")
                    case .demo: Text("Simula una Ranger PX 3.2 en ralentí. Útil para probar la terminal de Claude sin la camioneta.")
                    }
                }

                if model.kind == .ble {
                    Section("Adaptadores BLE — \(model.ble.state)") {
                        Button(model.ble.isScanning ? "Detener búsqueda" : "Buscar adaptadores") {
                            model.ble.isScanning ? model.ble.stopScan() : model.ble.startScan()
                        }
                        ForEach(model.ble.devices) { d in
                            Button {
                                selectedBLE = d.id
                                model.ble.select(d.id)
                            } label: {
                                HStack {
                                    Text(d.name)
                                    Spacer()
                                    Text("\(d.rssi) dBm").foregroundStyle(.secondary).font(.caption)
                                    if selectedBLE == d.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }

                if model.kind == .wifi {
                    Section("Adaptador Wi-Fi") {
                        TextField("IP", text: $model.wifiHost).keyboardType(.numbersAndPunctuation)
                        TextField("Puerto", text: $model.wifiPort).keyboardType(.numberPad)
                    }
                }

                Section {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        HStack {
                            Text(model.elm == nil ? "Conectar" : "Reconectar")
                            if model.isConnecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isConnecting || (model.kind == .ble && selectedBLE == nil))
                    if model.elm != nil {
                        Button("Desconectar", role: .destructive) { Task { await model.disconnect() } }
                    }
                } footer: {
                    Text(model.status)
                }

                if !model.vehicleSummary.isEmpty {
                    Section("Vehículo") {
                        ForEach(model.vehicleSummary.sorted { $0.key < $1.key }, id: \.key) { item in
                            LabeledContent(item.key, value: item.value)
                        }
                    }
                }

                Section("Base de PIDs") {
                    LabeledContent("Señales", value: "\(model.database.pids.count)")
                    LabeledContent("DIDs candidatos", value: "\(model.database.candidates.count)")
                    LabeledContent("Módulos", value: model.database.modules.joined(separator: ", "))
                }
            }
            .navigationTitle("RangerLink")
        }
    }
}
