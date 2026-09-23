import SwiftUI

@main
struct RangerLinkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ConnectView().tabItem { Label("Conexión", systemImage: "antenna.radiowaves.left.and.right") }
            LiveView().tabItem { Label("En vivo", systemImage: "gauge.with.dots.needle.67percent") }
            TerminalView().tabItem { Label("Claude", systemImage: "terminal") }
            LogView().tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            SettingsView().tabItem { Label("Ajustes", systemImage: "gearshape") }
        }
        .alert(model.prompt?.title ?? "", isPresented: Binding(
            get: { model.prompt != nil },
            set: { if !$0 { model.prompt = nil } }
        ), presenting: model.prompt) { p in
            Button(p.isConfirmation ? "Enviar" : "Listo") { p.resolve(true); model.prompt = nil }
            Button("Cancelar", role: .cancel) { p.resolve(false); model.prompt = nil }
        } message: { p in
            Text(p.message)
        }
    }
}
