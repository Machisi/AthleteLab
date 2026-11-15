import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

@MainActor final class Model: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var selectedDay = Calendar.current.startOfDay(for: Date.now)
    @Published var nightSleepHours: Double?
    @Published var nightDate: Date?
    @Published var weights: [WeightPoint] = []
    @Published var mealsDay: Date?
    @Published var nutritionBusy = false
    @Published var nutritionError: String?
    let nutritionCache = NutritionDiaryCache()
    private var nutritionRevision = 0
    @Published var hevyPairingPresented = false
    @Published var hevyLastImportAt: String?
    @Published var nutritionSource: String?
    @Published var liveHeart: Double?
    var mirrored: HKWorkoutSession?
    @Published var sessions: [Session] = []
    @Published var meals: [Meal] = []
    @Published var metrics: [Metric] = []
    @Published var connections: [String: Bool] = [:]
    @Published var connectionNotice: ConnectionNotice?
    private var readingHealth = false
    private var syncRequested = false
    @Published var message = "Conecta tus fuentes para empezar."
    @Published var busy = false
    @Published var lastSync: Date?
    @Published var plan: [Session] = []
    @Published var completed: Set<String> = []
    let website = WebsiteConnectionStore()
    let health = HKHealthStore()
    var observers: [HKObserverQuery] = []
    var auth: ASWebAuthenticationSession?
    var server: String { AppConfiguration.apiBaseURL }
    var providerSessionTask: Task<Void, Error>?
    var heartSummaryCache: [UUID: (Double, Double)] = [:]
    override init() {
        super.init()
        showCachedNutrition()
        website.onSnapshot = { [weak self] snapshot in self?.applyWebsite(snapshot) }
        // The private website must not launch an unrelated ChatGPT login.
        if UserDefaults.standard.bool(forKey: "healthSetupCompleted") { observeHealth() }
        health.workoutSessionMirroringStartHandler = { [weak self] session in Task { @MainActor in self?.mirrored = session; session.delegate = self } }
        if let data = UserDefaults.standard.data(forKey: "plan"), let value = try? JSONDecoder().decode([Session].self, from: data) { plan = value }
        completed = Set(UserDefaults.standard.stringArray(forKey: "completed") ?? [])
        if !UserDefaults.standard.bool(forKey: "seedCalendarV1") {
            do {
                guard let url = Bundle.main.url(forResource: "TrainingPlan", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let imported = try decoder.decode([Session].self, from: Data(contentsOf: url))
                let existing = Set(plan.map(\.id)); plan += imported.filter { !existing.contains($0.id) }
                savePlan(); UserDefaults.standard.set(true, forKey: "seedCalendarV1")
            } catch { message = "No se ha podido cargar tu calendario: \(error.localizedDescription)" }
        }
    }
    func savePlan() { if let data = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(data, forKey: "plan") } }
    func toggle(_ id: String) { if completed.contains(id) { completed.remove(id) } else { completed.insert(id) }; UserDefaults.standard.set(Array(completed), forKey: "completed") }
    func healthTypes() -> Set<HKObjectType> {
        Set([HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKObjectType.quantityType(forIdentifier: .heartRate)!, HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!, HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, HKObjectType.quantityType(forIdentifier: .restingHeartRate)!, HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!, HKObjectType.quantityType(forIdentifier: .vo2Max)!, HKObjectType.quantityType(forIdentifier: .bodyMass)!])
    }
    func connectHealth() async {
        do {
            guard HKHealthStore.isHealthDataAvailable() else { throw NSError(domain: "Salud", code: 0, userInfo: [NSLocalizedDescriptionKey: "Salud requiere un dispositivo compatible."]) }
            heartSummaryCache.removeAll()
            try await health.requestAuthorization(toShare: [], read: healthTypes())
            UserDefaults.standard.set(true, forKey: "healthSetupCompleted")
            observeHealth()
            message = "Solicitud de Salud procesada. Actualizando los registros disponibles."
            connectionNotice = ConnectionNotice(title: "Salud de Apple", message: "La solicitud se ha procesado. Si ya habías permitido o rechazado estos datos, iOS no vuelve a preguntar. Para cambiarlo, abre Salud → tu perfil → Apps → Athlete Lab y revisa Entrenamientos y Frecuencia cardiaca. Se actualizarán los datos que estén disponibles.")
            Task { await self.readHealth(); await self.readNight(for: self.selectedDay) }
        } catch { message = error.localizedDescription; connectionNotice = ConnectionNotice(title: "No se pudo acceder a Salud", message: message) }
    }
    func samples(_ type: HKSampleType, since: Date, limit: Int = HKObjectQueryNoLimit) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { c in
            health.execute(HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: since, end: .now), limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? []) }
            })
        }
    }
    func readHealth() async {
        guard !readingHealth else { return }; readingHealth = true; defer { readingHealth = false }
        do {
            let start = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            let workouts = try await samples(HKObjectType.workoutType(), since: start)
            var imported: [Session] = []
            for w in workouts.compactMap({ $0 as? HKWorkout }) {
                let sport = w.workoutActivityType == .swimming ? "Natación" : w.workoutActivityType == .cycling ? "Ciclismo" : [.traditionalStrengthTraining, .functionalStrengthTraining].contains(w.workoutActivityType) ? "Fuerza" : w.workoutActivityType == .running ? "Carrera" : "Actividad"
                var average = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                var maximum = w.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                if average == nil {
                    if let cached = heartSummaryCache[w.uuid] { average = cached.0; maximum = cached.1 }
                    else if let values = try? await workoutHeart(w), !values.points.isEmpty {
                        average = values.points.reduce(0) { $0 + $1.bpm } / Double(values.points.count); maximum = values.points.map(\.bpm).max()
                        if let average, let maximum { heartSummaryCache[w.uuid] = (average, maximum) }
                    }
                }
                imported.append(Session(id: w.uuid.uuidString, title: sport, sport: sport, date: w.startDate, minutes: w.duration / 60, distance: w.totalDistance?.doubleValue(for: .meter()), source: "Salud · \(w.sourceRevision.source.name)", detail: "Registro original de Salud de Apple.", calories: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()), averageHR: average, maximumHR: maximum, recordedEnd: w.endDate, recordingSource: w.sourceRevision.source.bundleIdentifier, externalIdentifier: (w.metadata?[HKMetadataKeySyncIdentifier] as? String) ?? (w.metadata?[HKMetadataKeyExternalUUID] as? String)))
            }
            sessions.removeAll { $0.source.hasPrefix("Salud") }; sessions += imported
            metrics = []
            weights = try await samples(HKQuantityType(.bodyMass), since: start).compactMap { $0 as? HKQuantitySample }.map { WeightPoint(date: $0.startDate, kg: $0.quantity.doubleValue(for: .gramUnit(with: .kilo))) }.sorted { $0.date < $1.date }
            for (id, type, unit, label, symbol) in [("Reposo", HKQuantityTypeIdentifier.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), "ppm", "heart.fill"), ("VFC", .heartRateVariabilitySDNN, .secondUnit(with: .milli), "ms", "waveform.path.ecg"), ("Peso", .bodyMass, .gramUnit(with: .kilo), "kg", "scalemass.fill"), ("VO₂ máx.", .vo2Max, HKUnit(from: "ml/kg*min"), "ml/kg/min", "lungs.fill")] {
                if let sample = try await samples(HKObjectType.quantityType(forIdentifier: type)!, since: start, limit: 1).first as? HKQuantitySample { metrics.append(Metric(id: id, value: sample.quantity.doubleValue(for: unit), unit: label, symbol: symbol)) }
            }
            let sleepStart = Calendar.current.date(byAdding: .hour, value: -24, to: .now)!
            let sleep = try await samples(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, since: sleepStart)
            // Select one source and merge overlaps; never sum overlapping Watch/Sleep Cycle records.
            let asleep = sleep.compactMap { $0 as? HKCategorySample }.filter { [1, 3, 4, 5].contains($0.value) }
            if let source = asleep.max(by: { $0.endDate < $1.endDate })?.sourceRevision.source.bundleIdentifier {
                let intervals = asleep.filter { $0.sourceRevision.source.bundleIdentifier == source }.map { (max($0.startDate, sleepStart), min($0.endDate, Date.now)) }.sorted { $0.0 < $1.0 }
                var end = sleepStart; var total = 0.0
                for (a, b) in intervals where b > end { total += b.timeIntervalSince(max(a, end)); end = b }
                if total > 0 { metrics.insert(Metric(id: "Sueño · 24 h", value: total / 3600, unit: "h", symbol: "bed.double.fill"), at: 0) }
            }
            lastSync = .now
        } catch { message = "Salud: \(error.localizedDescription)" }
    }
    func observeHealth() {
        guard observers.isEmpty else { return }
        for type in healthTypes().compactMap({ $0 as? HKSampleType }) {
            let q = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor in if error == nil { self?.heartSummaryCache.removeAll(); await self?.readHealth(); if let self { await self.readNight(for: self.selectedDay) } }; completion() }
            }
            observers.append(q); health.execute(q)
            health.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }
    func request(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        guard let base = URL(string: server), base.scheme == "https", base.host != nil else {
            throw NSError(domain: "Conexión", code: 1, userInfo: [NSLocalizedDescriptionKey: "El servicio de Strava y FatSecret está pendiente de activación. No necesitas una cuenta de Athlete Lab."])
        }
        for attempt in 0...1 {
            if path.hasPrefix("api/") { try await ensureProviderSession() }
            var r = URLRequest(url: base.appendingPathComponent(path)); r.httpMethod = method; r.timeoutInterval = 25
            r.setValue("AthleteLab/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"), forHTTPHeaderField: "User-Agent")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            if path.hasPrefix("api/") { r.setValue("Bearer \(Vault.get("providerSession"))", forHTTPHeaderField: "Authorization") }
            if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await URLSession.shared.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 && path.hasPrefix("api/") && attempt == 0 {
                try Vault.set("", "providerSession"); try await ensureProviderSession(force: true); continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let serverError = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                let explanation = http.statusCode == 503 ? "La integración de Athlete Lab con este servicio aún no está configurada. No es un fallo de tu cuenta ni se arregla volviendo a iniciar sesión." : (serverError ?? "El servicio no pudo completar la petición (\(http.statusCode)).")
                throw NSError(domain: "Conexión", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: explanation])
            }
            return data
        }
        throw URLError(.userAuthenticationRequired)
    }
    func showCachedNutrition() {
        meals = nutritionCache.meals(for: NutritionDiaryCache.dayKey(selectedDay)) ?? []
        mealsDay = selectedDay; nutritionError = nil
    }
    func clearNutritionCache() {
        nutritionRevision += 1; nutritionBusy = false; nutritionCache.removeAll()
        meals = []; mealsDay = nil; nutritionSource = nil; nutritionError = nil
    }
    func refreshNutrition() async {
        let day = selectedDay, key = NutritionDiaryCache.dayKey(selectedDay)
        nutritionRevision += 1; let revision = nutritionRevision
        nutritionBusy = true
        defer { if revision == nutritionRevision { nutritionBusy = false } }
        do {
            let data = try await request("api/nutrition", method: "POST", body: ["date": key])
            let value = try JSONDecoder().decode(NutritionResponse.self, from: data)
            guard revision == nutritionRevision else { return }
            if value.mealStatus == "complete" {
                nutritionCache.save(value.meals, for: key)
                if Calendar.current.isDate(day, inSameDayAs: selectedDay) {
                    meals = value.meals; mealsDay = day; nutritionSource = "FatSecret · conexión directa"; nutritionError = nil
                }
            } else if !value.connected {
                clearNutritionCache(); connections["fatsecret"] = false
            } else if Calendar.current.isDate(day, inSameDayAs: selectedDay) {
                nutritionError = value.error ?? "No se pudo actualizar el diario. Se conservan los alimentos disponibles."
            }
        } catch {
            if revision == nutritionRevision && Calendar.current.isDate(day, inSameDayAs: selectedDay) { nutritionError = error.localizedDescription }
        }
    }
    func sync() async {
        guard !busy else { syncRequested = true; return }
        busy = true
        defer {
            busy = false
            if syncRequested { syncRequested = false; Task { await self.sync() } }
        }
        async let healthRefresh: Void = readHealth()
        async let nightRefresh: Void = readNight(for: selectedDay)
        async let foodRefresh: Void = refreshNutrition()

        guard !server.isEmpty else { return }
        do {
            let requestedDay = selectedDay
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            let data = try await request("api/sync", method: "POST", body: ["date": formatter.string(from: requestedDay), "includeNutrition": "false"])
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let remote = try decoder.decode(RemoteData.self, from: data)
            sessions.removeAll { ["Strava", "FatSecret"].contains($0.source) }; sessions += remote.sessions.filter { $0.source != "Hevy" }; if remote.hevyStatus == "complete" { sessions.removeAll { $0.source == "Hevy" }; sessions += remote.sessions.filter { $0.source == "Hevy" } }; hevyLastImportAt = remote.hevyLastImportAt
            connections.merge(remote.connections) { _, new in new }; lastSync = .now
            message = remote.warnings.isEmpty ? "Sincronización terminada." : remote.warnings.joined(separator: "\n")
        } catch { message = error.localizedDescription }
        _ = await (healthRefresh, nightRefresh, foodRefresh)
    }
    // Use the same grouping for Today, History, charts and weekly kilometre totals.
    var uniqueSessions: [Session] { SessionDeduplication.grouped(sessions) }
    func connectHevyCode(_ code: String) async throws {
        _ = try await request("api/connect/hevy", method: "POST", body: ["code": code])
        await sync()
        guard connections["hevy"] == true else { throw URLError(.badServerResponse) }
    }
    func connect(_ provider: String) async {
        if provider == "hevy" { hevyPairingPresented = true; return }
        let name = provider == "hevy" ? "Hevy" : provider == "strava" ? "Strava" : "FatSecret"
        guard !server.isEmpty else {
            message = "El servicio de autorización de \(name) todavía no está activado."
            connectionNotice = ConnectionNotice(title: "\(name) pendiente de activación", message: "La conexión directa aún no está configurada: faltan un servicio de autorización publicado y las credenciales de desarrollador de Athlete Lab. Abrir una página de inicio de sesión por sí solo no conecta tu diario ni tus actividades. No se abrirá ChatGPT. La vinculación se realizará directamente con el proveedor cuando su configuración esté activa.")
            return
        }
        do {
            let data = try await request("api/connect/\(provider)", method: "POST")
            let payload = try JSONDecoder().decode([String: String].self, from: data)
            guard let value = payload["url"], let url = URL(string: value), url.scheme == "https", url.host == (provider == "hevy" ? "athlete-lab-marc.grittylion20.chatgpt.site" : provider == "fatsecret" ? "authentication.fatsecret.com" : "www.strava.com") else { throw URLError(.badServerResponse) }
            auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "athletelab") { [weak self] url, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.message = error.localizedDescription; self.connectionNotice = ConnectionNotice(title: "Autorización interrumpida", message: self.message); return }
                    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                    if url?.host == "oauth" && items.contains(where: { $0.name == "provider" && $0.value == provider }) && items.contains(where: { $0.name == "success" && $0.value == "1" }) {
                        if provider == "fatsecret" { self.clearNutritionCache() }; await self.sync(); self.connectionNotice = ConnectionNotice(title: self.connections[provider] == true ? "Cuenta autorizada" : "No se pudo confirmar la conexión", message: self.message)
                    } else { self.message = "La autorización no se completó."; self.connectionNotice = ConnectionNotice(title: "No se pudo conectar", message: self.message) }
                }
            }
            auth?.presentationContextProvider = self
            guard auth?.start() == true else { throw NSError(domain: "Autorización", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo abrir la ventana de autorización. Inténtalo de nuevo."]) }
        } catch { message = error.localizedDescription; connectionNotice = ConnectionNotice(title: "No se pudo conectar \(name)", message: message) }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

