import SwiftUI
import OBDCore

/// Tráfico crudo con el ELM327: todo lo que manda la app o Claude, y lo que responde.
struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List(model.log.suffix(500)) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.direction.rawValue).foregroundStyle(color(line.direction))
                    Text(line.text).textSelection(.enabled)
                }
                .font(.caption.monospaced())
            }
            .listStyle(.plain)
            .navigationTitle("Log crudo")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Borrar") { model.clearLog() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.logText, preview: SharePreview("rangerlink-log.txt"))
                }
            }
        }
    }

    private func color(_ d: LogLine.Direction) -> Color {
        switch d {
        case .tx: return .blue
        case .rx: return .green
        case .info: return .orange
        }
    }
}
