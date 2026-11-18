import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

struct Connections: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var appearance: AppearanceStore
    @ViewState private var runningActions: Set<String> = []
    @AppStorage("weeklyKmGoal") var weeklyKmGoal = 0.0
    @AppStorage("sleepGoalHours") var sleepGoalHours = 0.0
    var body: some View { Form {
        Section {
            HStack(spacing: 14) {
                Image("BrandLogo").resizable().scaledToFit().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) { Text("Athlete Lab").font(.title3.bold()); Text("Tu entrenamiento, en perspectiva.").font(.caption).foregroundStyle(.secondary); Text("Versión " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(.caption2).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }

        Section("Atleta") {
            NavigationLink { AthleteProfileView() } label: { Label("Perfil y datos físicos", systemImage: "person.crop.circle") }
            NavigationLink { UpcomingRacesView() } label: { Label("Mis carreras y objetivos", systemImage: "flag.checkered") }
        }
        Section("Apariencia") {
            Toggle(isOn: $appearance.isDark) {
                Label("Modo negro", systemImage: "moon.fill")
            }.tint(LabPalette.accent)
        }
        Section("Objetivos de los anillos") {
            HStack { Text("Kilómetros por semana"); Spacer(); TextField("Sin objetivo", value: $weeklyKmGoal, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }
                .onChange(of: weeklyKmGoal) { _, value in if !value.isFinite || value < 0 { weeklyKmGoal = 0 } }
            HStack { Text("Horas de sueño"); Spacer(); TextField("Sin objetivo", value: $sleepGoalHours, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }
                .onChange(of: sleepGoalHours) { _, value in if !value.isFinite || value < 0 { sleepGoalHours = 0 } }
            Text("El anillo de recuperación muestra cuánto sueño has registrado respecto a tu objetivo. Un valor de 0 deja el objetivo sin definir.").font(.caption).foregroundStyle(.secondary)
        }

        Section("Salud y descanso") {
            Button { perform("health") { await m.connectHealth() } } label: {
                HStack { Label("Conectar / revisar Salud", systemImage: "heart.fill"); Spacer(); if runningActions.contains("health") { ProgressView() } else { Image(systemName: "chevron.right").font(.caption) } }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.borderless).disabled(runningActions.contains("health"))
            Text("Si ya decidiste los permisos, iOS no vuelve a mostrar la solicitud. La app te confirmará que la ha procesado.").font(.caption).foregroundStyle(.secondary)
            Text("Funciona directamente en tu iPhone. Sleep Cycle se lee a través de lo que publique en Salud.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Conectar mis cuentas") {
            ForEach(["fatsecret", "hevy", "strava"], id: \.self) { provider in
                Button {
                    perform(provider) { await m.connect(provider) }
                } label: {
                    let connected = m.connections[provider] == true
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(providerName(provider), systemImage: provider == "hevy" ? "dumbbell.fill" : provider == "strava" ? "figure.run" : "fork.knife")
                                .font(.headline)
                            if connected {
                                Label("Conectado", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 6)
                        if runningActions.contains(provider) {
                            ProgressView().accessibilityLabel("Procesando conexión")
                        } else {
                            Text(connected ? "Gestionar" : "Conectar")
                                .font(.caption.weight(.semibold)).padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .foregroundStyle(connected ? LabPalette.accent : LabPalette.ink)
                                .background(connected ? LabPalette.accent.opacity(0.10) : LabPalette.coral, in: Capsule())
                        }
                    }.foregroundStyle(.primary).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(runningActions.contains(provider))
            }
            Text("Hevy reutiliza los entrenamientos importados a tu espacio privado mediante ChatGPT. Vincula este iPhone con un código de un solo uso; no necesitas una clave API ni abrir ChatGPT en el móvil. Los nuevos registros llegan cuando se actualiza esa importación.").font(.caption).foregroundStyle(.secondary)
            Text("Cada cuenta requiere su propia autorización. Salud es una conexión independiente y no se utiliza para vincular Hevy, FatSecret o Strava.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Estado de conexiones") { Text(m.message).font(.footnote) }
        Section("Desconectar cuentas") {
            ForEach(["strava", "fatsecret", "hevy"].filter { m.connections[$0] == true }, id: \.self) { provider in
                Button("Desconectar \(provider)", role: .destructive) { perform(provider) { await m.disconnect(provider) } }.buttonStyle(.borderless)
            }
        }
    }.scrollContentBackground(.hidden).background(LabPalette.canvas)
    .sensoryFeedback(.success, trigger: m.connections) { previous, current in
        current.contains { $0.value && previous[$0.key] != true }
    }
    .sheet(isPresented: $m.hevyPairingPresented) { HevyPairingView() }.alert(item: $m.connectionNotice) { notice in Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("Entendido"))) }
    .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Cerrar teclado") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } }
    }
    private func providerName(_ provider: String) -> String { provider == "hevy" ? "Hevy" : provider == "strava" ? "Strava" : "FatSecret" }
    private func perform(_ key: String, action: @escaping @MainActor () async -> Void) {
        guard !runningActions.contains(key) else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        runningActions.insert(key)
        Task { @MainActor in await action(); runningActions.remove(key) }
    }
}



struct HevyPairingView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    @ViewState private var code = ""
    @ViewState private var connecting = false
    @ViewState private var error: String?
    var body: some View {
        NavigationStack { Form {
            Section {
                Label("Tu importación de Hevy", systemImage: "dumbbell.fill").font(.headline)
                Text("Introduce el código de vinculación que te hemos facilitado para conectar este iPhone con tus entrenamientos de Hevy.")
                TextField("Código de 12 caracteres", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button {
                    connecting = true; error = nil
                    Task { @MainActor in
                        do { try await m.connectHevyCode(code); dismiss() }
                        catch { self.error = error.localizedDescription }
                        connecting = false
                    }
                } label: { HStack { Text("Vincular Hevy"); Spacer(); if connecting { ProgressView() } } }
                .buttonStyle(LabActionStyle())
                .disabled(connecting || code.filter { !$0.isWhitespace && $0 != "-" }.count != 12)
            } footer: {
                Text("El código caduca a las 24 horas y solo se utiliza una vez. Los datos proceden de la misma importación de Hevy que usa tu web, sin pasar por Salud. Si necesitas otro código, pídelo en esta conversación.")
            }
        }.navigationTitle("Conectar Hevy").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(connecting) } } }
    }
}
