import SwiftUI
import OBDCore

/// Terminal: lo que escribes va a Claude, que decide qué medir y lo ejecuta en la
/// camioneta. Empieza con ">" para mandar un comando crudo al ELM327 tú mismo
/// (p. ej. "> 22 F4 5C"). "/reset" borra la conversación.
struct TerminalView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var focused: Bool

    private let examples = [
        "Revisa el balance de los 5 inyectores en ralentí y dime si alguno está fallando",
        "¿Cómo está el DPF? ¿Cuándo fue la última regeneración?",
        "Haz una prueba de turbo: compara boost comandado vs real al acelerar",
        "Lee todos los códigos de falla y explícamelos",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if model.chat.isEmpty {
                                Text("Pídele a Claude un diagnóstico. Él elige los PIDs, los lee en vivo y te explica el resultado.")
                                    .foregroundStyle(.secondary)
                                ForEach(examples, id: \.self) { e in
                                    Button(e) { input = e; focused = true }
                                        .buttonStyle(.bordered)
                                        .font(.callout)
                                }
                            }
                            ForEach(model.chat) { item in
                                ChatRow(item: item).id(item.id)
                            }
                            if model.agentBusy {
                                HStack { ProgressView(); Text("Claude trabajando…").foregroundStyle(.secondary) }
                                    .id("busy")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.chat.count) {
                        withAnimation {
                            if model.agentBusy {
                                proxy.scrollTo("busy", anchor: .bottom)
                            } else if let id = model.chat.last?.id {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }
                Divider()
                HStack(alignment: .bottom) {
                    TextField("Pregunta a Claude, o > comando crudo", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .font(.body.monospaced())
                    if model.agentBusy {
                        Button { model.cancelAgent() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                            .tint(.red)
                    } else {
                        Button {
                            model.submit(input)
                            input = ""
                        } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(10)
            }
            .navigationTitle("Terminal Claude")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ChatRow: View {
    let item: ChatItem
    @State private var expanded = false

    var body: some View {
        switch item {
        case .user(_, let t):
            Text(t)
                .padding(10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let t):
            Text((try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t))
                .textSelection(.enabled)
        case .thinking(_, let t):
            DisclosureGroup(isExpanded: $expanded) {
                Text(t).font(.caption).foregroundStyle(.secondary)
            } label: {
                Label("Razonamiento", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        case .tool(_, let name, let input, let output, let isError):
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(input).font(.caption2.monospaced())
                    if let output {
                        Divider()
                        Text(output.count > 4000 ? String(output.prefix(4000)) + "…" : output)
                            .font(.caption2.monospaced())
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: output == nil ? "hourglass" : (isError ? "xmark.octagon" : "checkmark.circle"))
                        .foregroundStyle(output == nil ? .orange : (isError ? .red : .green))
                    Text("▶ \(name)").font(.caption.monospaced())
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .system(_, let t):
            Text(t).font(.caption).foregroundStyle(.orange)
        case .raw(_, let command, let response):
            VStack(alignment: .leading, spacing: 2) {
                Text("> \(command)").font(.caption.monospaced()).foregroundStyle(.green)
                Text(response).font(.caption.monospaced()).textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }
    }
}
