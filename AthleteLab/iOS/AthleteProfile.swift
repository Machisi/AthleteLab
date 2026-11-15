import SwiftUI

struct AthleteProfile: Codable {
    var name = ""
    var hasBirthday = false
    var birthday = Date.now
    var weightKg: Double? = nil
    var weightDate: Date? = nil
    var heightCm: Double? = nil
    var experience = "Sin especificar"
    var weeklyHours: Double? = nil
    var goal = ""
    var restDays = ""
    var notes = ""
    var races: [AthleteRace] = []
}
struct AthleteRace: Identifiable, Codable {
    var id = UUID()
    var name = ""
    var date = Date.now
    var sport = "Triatlón"
    var distance = ""
    var location = ""
    var target = ""
    var priority = "Principal"
}
@MainActor final class AthleteProfileStore: ObservableObject {
    @Published var profile: AthleteProfile { didSet { save() } }
    init() {
        if let data = UserDefaults.standard.data(forKey: "athleteProfileV1"), let profile = try? JSONDecoder().decode(AthleteProfile.self, from: data) { self.profile = profile }
        else { profile = AthleteProfile() }
    }
    private func save() { if let data = try? JSONEncoder().encode(profile) { UserDefaults.standard.set(data, forKey: "athleteProfileV1") } }
}
struct AthleteProfileView: View {
    @EnvironmentObject var athlete: AthleteProfileStore
    var body: some View { Form {
        Section("Perfil de atleta") {
            TextField("Nombre", text: $athlete.profile.name).textContentType(.givenName)
            Toggle("Añadir fecha de nacimiento", isOn: $athlete.profile.hasBirthday)
            if athlete.profile.hasBirthday { DatePicker("Nacimiento", selection: $athlete.profile.birthday, in: ...Date.now, displayedComponents: .date) }
            Picker("Experiencia", selection: $athlete.profile.experience) { ForEach(["Sin especificar", "Principiante", "Intermedio", "Avanzado"], id: \.self) { Text($0) } }
        }
        Section("Medidas") {
            optionalNumber("Peso · kg", value: $athlete.profile.weightKg)
                .onChange(of: athlete.profile.weightKg) { _, value in athlete.profile.weightDate = value == nil ? nil : .now }
            if let date = athlete.profile.weightDate { Text("Peso anotado el \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
            optionalNumber("Altura · cm", value: $athlete.profile.heightCm)
            Text("Medidas anotadas por ti. No se escriben en Salud ni sustituyen sus registros.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Preparación") {
            TextField("Objetivo deportivo", text: $athlete.profile.goal, axis: .vertical)
            optionalNumber("Horas disponibles por semana", value: $athlete.profile.weeklyHours)
            TextField("Días de descanso", text: $athlete.profile.restDays)
            TextField("Limitaciones, molestias o aspectos a considerar", text: $athlete.profile.notes, axis: .vertical).lineLimit(3...6)
        }
        Section { Text("Se guarda automáticamente en este dispositivo. Estos datos aportan contexto; todavía no modifican automáticamente el plan ni los indicadores de recuperación.").font(.caption).foregroundStyle(.secondary) }
    }.navigationTitle("Perfil de atleta").navigationBarTitleDisplayMode(.inline) }
    private func optionalNumber(_ title: String, value: Binding<Double?>) -> some View {
        HStack { Text(title); Spacer(); TextField("Sin indicar", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110) }
            .onChange(of: value.wrappedValue) { _, new in if let new, !new.isFinite || new <= 0 { value.wrappedValue = nil } }
    }
}
struct UpcomingRacesView: View {
    @EnvironmentObject var athlete: AthleteProfileStore
    @ViewState private var editing: AthleteRace?
    var body: some View { List {
        if athlete.profile.races.isEmpty { ContentUnavailableView("Tus próximas metas", systemImage: "flag.checkered", description: Text("Añade una carrera, su fecha y tu objetivo.")) }
        ForEach(athlete.profile.races.sorted { $0.date < $1.date }) { race in
            Button { editing = race } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(race.name).font(.headline); Spacer(); Text(race.priority).font(.caption).foregroundStyle(.secondary) }
                    Text(race.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
                    Text([race.sport, race.distance, race.location].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if !race.target.isEmpty { Label(race.target, systemImage: "target").font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 6)
            }.buttonStyle(.plain).swipeActions { Button("Eliminar", role: .destructive) { athlete.profile.races.removeAll { $0.id == race.id } } }
        }
    }.navigationTitle("Mis carreras").toolbar { Button { editing = AthleteRace() } label: { Image(systemName: "plus") } }.sheet(item: $editing) { race in RaceEditor(race: race) } }
}
struct RaceEditor: View {
    @EnvironmentObject var athlete: AthleteProfileStore
    @Environment(\.dismiss) var dismiss
    @ViewState var race: AthleteRace
    var body: some View { NavigationStack { Form {
        Section("La carrera") {
            TextField("Nombre de la prueba", text: $race.name)
            DatePicker("Fecha", selection: $race.date, displayedComponents: .date)
            Picker("Deporte", selection: $race.sport) { ForEach(["Triatlón", "Carrera", "Ciclismo", "Natación", "Otro"], id: \.self) { Text($0) } }
            TextField("Distancia o modalidad · p. ej. 70.3", text: $race.distance)
            TextField("Lugar", text: $race.location)
        }
        Section("Tu objetivo") {
            TextField("Marca o propósito · p. ej. sub 5 h", text: $race.target)
            Picker("Prioridad", selection: $race.priority) { ForEach(["Principal", "Secundaria", "Preparación"], id: \.self) { Text($0) } }
        }
    }.navigationTitle("Carrera").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Guardar") {
            if let index = athlete.profile.races.firstIndex(where: { $0.id == race.id }) { athlete.profile.races[index] = race }
            else { athlete.profile.races.append(race) }; dismiss()
        }.disabled(race.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    } } }
}
