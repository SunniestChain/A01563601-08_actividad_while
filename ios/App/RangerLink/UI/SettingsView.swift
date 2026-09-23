import SwiftUI
import OBDCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-...", text: $model.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Modelo", selection: $model.model) {
                        ForEach(ClaudeConfig.models, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Esfuerzo", selection: $model.effort) {
                        ForEach(ClaudeConfig.efforts, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(model.model.hasPrefix("claude-haiku"))
                    Button("Guardar") { model.saveSettings() }
                } header: {
                    Text("Claude (API de Anthropic)")
                } footer: {
                    Text("La key se guarda en el Keychain del iPhone. Cada diagnóstico cuesta tokens: Opus razona mejor, Sonnet/Haiku son más baratos y rápidos. Guardar reinicia la memoria de la conversación.")
                }

                Section("Seguridad") {
                    Text("Sólo lectura. Claude no puede escribir, programar, ejecutar rutinas ni hacer reset de módulos. Borrar códigos o abrir sesión extendida siempre te pide confirmación.")
                        .font(.callout)
                    Text("No uses la app mientras manejas. Las pruebas en movimiento las opera un acompañante.")
                        .font(.callout).foregroundStyle(.orange)
                }

                Section("Acerca de los PIDs") {
                    Text("La base NO es la de FORScan (es propietaria). Son PIDs SAE estándar más DIDs Ford recopilados de la comunidad, cada uno con su nivel de confianza. Valida los ford-generic y ford-diesel-sibling en tu camioneta.")
                        .font(.callout)
                }
            }
            .navigationTitle("Ajustes")
        }
    }
}
