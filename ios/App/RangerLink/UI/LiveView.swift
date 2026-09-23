import Charts
import SwiftUI
import OBDCore

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                if model.elm == nil {
                    Text("Conecta un adaptador en la pestaña Conexión.").foregroundStyle(.secondary)
                }
                if model.agentBusy && model.liveRunning {
                    Label("En pausa mientras Claude usa el adaptador", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
                ForEach(model.selectedIDs, id: \.self) { id in
                    if let def = model.database[id] {
                        LiveRow(def: def, reading: model.live[id], history: model.history[id] ?? [])
                    }
                }
                .onDelete { idx in idx.map { model.selectedIDs[$0] }.forEach(model.toggle) }
            }
            .navigationTitle("En vivo")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPicker = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.liveRunning ? "Pausa" : "Iniciar") {
                        model.liveRunning ? model.stopLive() : model.startLive()
                    }
                    .disabled(model.elm == nil)
                }
            }
            .sheet(isPresented: $showPicker) { PIDPicker() }
        }
    }
}

struct LiveRow: View {
    let def: PIDDefinition
    let reading: PIDReading?
    let history: [(Date, Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(def.name_es).font(.subheadline)
                    Text("\(def.module) \(def.command) · \(def.confidence)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let v = reading?.value {
                    Text(v, format: .number.precision(.fractionLength(0...2))).font(.title3.monospacedDigit())
                    Text(def.unit).font(.caption).foregroundStyle(.secondary)
                } else if let e = reading?.error {
                    Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            if history.count > 2 {
                Chart(Array(history.enumerated()), id: \.offset) { item in
                    LineMark(x: .value("t", item.element.0), y: .value("v", item.element.1))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .frame(height: 44)
            }
            if let raw = reading?.raw {
                Text(raw).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

struct PIDPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let groups = Dictionary(grouping: model.database.search(query), by: \.category)
                ForEach(groups.keys.sorted(), id: \.self) { cat in
                    Section(cat) {
                        ForEach(groups[cat] ?? []) { p in
                            Button { model.toggle(p.id) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(p.name_es).foregroundStyle(.primary)
                                        Text("\(p.id) · \(p.unit) · \(p.confidence)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.selectedIDs.contains(p.id) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "rpm, riel, dpf, inyección, 6R80...")
            .navigationTitle("Señales")
            .toolbar { Button("Listo") { dismiss() } }
        }
    }
}
