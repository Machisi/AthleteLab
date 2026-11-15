import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

struct Session: Identifiable, Codable {
    var id: String; var title: String; var sport: String; var date: Date; var minutes: Double
    var distance: Double?; var source: String; var detail: String
    var calories: Double? = nil
    var averageHR: Double? = nil
    var maximumHR: Double? = nil
    var recordedEnd: Date? = nil
    var recordingSource: String? = nil
    var externalIdentifier: String? = nil
    var symbol: String { sport == "Natación" ? "figure.pool.swim" : sport == "Ciclismo" ? "figure.outdoor.cycle" : sport == "Fuerza" ? "dumbbell.fill" : "figure.run" }
}
struct Meal: Identifiable, Codable {
    var id: String; var title: String; var calories: Double; var protein: Double; var carbs: Double; var fat: Double
    var mealType: String? = nil
    var servingDescription: String? = nil
    var category: MealCategory { MealCategory(rawValue: (mealType ?? "").lowercased()) ?? .other }
}
enum MealCategory: String, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, other
    var id: String { rawValue }
    var title: String { switch self { case .breakfast: "Desayuno"; case .lunch: "Comida"; case .dinner: "Cena"; case .other: "Tentempiés" } }
    var symbol: String { switch self { case .breakfast: "sunrise"; case .lunch: "sun.max"; case .dinner: "moon"; case .other: "carrot" } }
}
struct NutritionTotals {
    var calories = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0
    init(_ meals: [Meal]) {
        for meal in meals { calories += meal.calories; protein += meal.protein; carbs += meal.carbs; fat += meal.fat }
    }
    static func progress(_ value: Double, toward goal: Double) -> Double? {
        guard value.isFinite, goal.isFinite, goal > 0 else { return nil }
        return min(max(value / goal, 0), 1)
    }
}
// Only confirmed provider responses enter this bounded local diary cache.
final class NutritionDiaryCache {
    struct Entry: Codable { var meals: [Meal]; var savedAt: Date }
    private let file: URL
    private let capacity: Int
    private var days: [String: Entry]
    init(file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("nutrition-diary-v1.json"), capacity: Int = 120) {
        self.file = file; self.capacity = capacity
        days = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
    }
    static func dayKey(_ day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func meals(for key: String) -> [Meal]? { days[key]?.meals }
    func save(_ meals: [Meal], for key: String, now: Date = .now) {
        days[key] = Entry(meals: meals, savedAt: now)
        for key in days.sorted(by: { $0.value.savedAt > $1.value.savedAt }).dropFirst(capacity).map(\.key) { days.removeValue(forKey: key) }
        persist()
    }
    func removeAll() { days.removeAll(); try? FileManager.default.removeItem(at: file) }
    private func persist() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: file, options: .atomic)
        #endif
    }
}
struct NutritionResponse: Codable { var meals: [Meal]; var mealStatus: String; var connected: Bool; var error: String? }
struct Metric: Identifiable { var id: String; var value: Double; var unit: String; var symbol: String }
struct RemoteData: Codable { var sessions: [Session]; var meals: [Meal]; var connections: [String: Bool]; var warnings: [String]; var mealStatus: String? = nil; var hevyStatus: String? = nil; var hevyLastImportAt: String? = nil }
enum Vault {
    static func get(_ key: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AthleteLab", kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func set(_ value: String, _ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AthleteLab", kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        if value.isEmpty { return }
        var item = query; item[kSecValueData as String] = Data(value.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
    }
}

struct HeartPoint: Identifiable, Codable {
    var seconds: Double; var bpm: Double
    var id: Double { seconds }
}
struct RoutePoint: Codable { var latitude: Double; var longitude: Double }
struct ActivityDetail: Codable {
    var heartSource: String? = nil
    var calories: Double? = nil
    var averageHR: Double? = nil
    var maximumHR: Double? = nil
    var heart: [HeartPoint] = []
    var route: [RoutePoint] = []
}
struct WeightPoint: Identifiable { var date: Date; var kg: Double; var id: Date { date } }

enum DashboardMath {
    static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        var c = calendar; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4
        return c.dateInterval(of: .weekOfYear, for: date)!
    }
    static func kilometres(_ sessions: [Session], in interval: DateInterval) -> Double {
        sessions.filter { $0.date >= interval.start && $0.date < interval.end }.reduce(0) { $0 + max(0, $1.distance ?? 0) / 1000 }
    }
    static func mergedHours(_ intervals: [DateInterval]) -> Double {
        var end = Date.distantPast; var seconds = 0.0
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.end > end {
            seconds += interval.end.timeIntervalSince(max(interval.start, end)); end = interval.end
        }
        return seconds / 3600
    }
}

struct TrainingStep: Identifiable {
    let number: Int
    let text: String
    var id: Int { number }
}
struct TrainingText {
    let steps: [TrainingStep]
    let notes: [String]
    init(_ raw: String) {
        let cleaned = raw.replacingOccurrences(of: "(?m)^ATHLETE LAB[^\\n]*(?:\\n|$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^TU ENTRENAMIENTO\\s*\\n?", with: "", options: .regularExpression)
            .replacingOccurrences(of: " · Hora de Madrid", with: "")
        var steps: [TrainingStep] = []; var notes: [String] = []
        for paragraph in cleaned.components(separatedBy: "\n\n") {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // The session header already presents the local time; don't repeat it in the exercises.
            let lines = text.components(separatedBy: "\n").filter { !$0.range(of: "^\\d{2}:\\d{2}[–—-]\\d{2}:\\d{2}$", options: .regularExpression).isSome }
            let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let range = value.range(of: "^\\d+[.\\-]\\s+", options: .regularExpression) {
                let number = Int(value[range].filter(\.isNumber)) ?? steps.count + 1
                steps.append(TrainingStep(number: number, text: String(value[range.upperBound...])))
            } else { notes.append(value) }
        }
        self.steps = steps; self.notes = notes
    }
    var preview: String {
        let exerciseText = steps.map { "\($0.number)- \($0.text)" }.joined(separator: "\n")
        return exerciseText.isEmpty ? notes.joined(separator: "\n\n") : exerciseText
    }
}
private extension Optional { var isSome: Bool { self != nil } }

struct HeartReading {
    let date: Date
    let bpm: Double
    let source: String
}
enum HeartTimeline {
    static func select(_ readings: [HeartReading], start: Date, end: Date, preferred: String) -> [HeartReading] {
        let groups = Dictionary(grouping: readings.filter { $0.date >= start && $0.date < end && $0.bpm.isFinite && $0.bpm > 0 }, by: \.source)
        // One source only: avoid interleaving watch and chest-strap readings.
        let keys = groups.keys.sorted { a, b in
            let aPreferred = a.hasPrefix(preferred + "|"); let bPreferred = b.hasPrefix(preferred + "|")
            if aPreferred != bPreferred { return aPreferred }
            if groups[a]!.count != groups[b]!.count { return groups[a]!.count > groups[b]!.count }
            return a < b
        }
        guard let key = keys.first else { return [] }
        var used = Set<Date>()
        return groups[key]!.sorted { $0.date < $1.date }.filter { used.insert($0.date).inserted }
    }
}

struct ConnectionNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// Wire format of the existing Athlete Lab website. No provider credentials enter the app.
struct WebsiteSnapshot: Decodable {
    let records: [WebsiteRecord]
    let providers: [String: WebsiteProvider]
    func meals(on day: Date, calendar: Calendar = .current) -> [Meal] {
        guard providers["fatsecret"]?.connected == true else { return [] }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        var used = Set<String>()
        return records.filter { $0.source == "fatsecret" && $0.category == "food" && String($0.occurred.prefix(10)) == key && used.insert($0.id).inserted }.map {
            Meal(id: "web-" + $0.id, title: $0.payload.name ?? "Alimento", calories: max(0, $0.payload.kcal ?? 0), protein: max(0, $0.payload.protein ?? 0), carbs: max(0, $0.payload.carbs ?? 0), fat: max(0, $0.payload.fat ?? 0))
        }
    }
    var sessions: [Session] {
        var used = Set<String>()
        return records.compactMap { row in
            guard row.category == "workout", ["hevy", "strava"].contains(row.source), providers[row.source]?.connected == true, used.insert(row.id).inserted, let date = WebsiteRecord.date(row.occurred), let minutes = row.payload.minutes, minutes > 0 else { return nil }
            let sport = ["run": "Carrera", "bike": "Ciclismo", "swim": "Natación", "strength": "Fuerza"][row.payload.sport ?? ""] ?? "Actividad"
            return Session(id: "web-" + row.id, title: row.payload.name ?? sport, sport: sport, date: date, minutes: minutes, distance: row.payload.distanceKm.map { max(0, $0) * 1000 }, source: "Web · " + (row.source == "hevy" ? "Hevy" : "Strava"), detail: row.payload.trainingDetail, calories: row.payload.calories, averageHR: row.payload.averageHR, maximumHR: row.payload.maxHR)
        }
    }
    func detail(for id: String) -> ActivityDetail? {
        guard let row = records.first(where: { "web-" + $0.id == id }) else { return nil }
        let samples = row.payload.samples ?? []
        return ActivityDetail(heartSource: samples.contains(where: { ($0.hr ?? 0) > 0 }) ? "Strava · datos guardados en tu web" : nil, calories: row.payload.calories, averageHR: row.payload.averageHR, maximumHR: row.payload.maxHR, heart: samples.compactMap { sample in guard let bpm = sample.hr, bpm > 0 else { return nil }; return HeartPoint(seconds: sample.seconds, bpm: bpm) }, route: samples.compactMap { sample in guard let point = sample.latlng, point.count == 2, abs(point[0]) <= 90, abs(point[1]) <= 180 else { return nil }; return RoutePoint(latitude: point[0], longitude: point[1]) })
    }
}
struct WebsiteProvider: Decodable { let configured: Bool; let connected: Bool; let mode: String? }
struct WebsiteRecord: Decodable {
    let id: String; let category: String; let source: String; let occurred: String; let payload: WebsitePayload
    private enum CodingKeys: String, CodingKey { case id, category, source, occurred, payload }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        category = try fields.decode(String.self, forKey: .category)
        source = try fields.decode(String.self, forKey: .source)
        occurred = try fields.decode(String.self, forKey: .occurred)
        if ["fatsecret", "hevy", "strava"].contains(source) {
            payload = try fields.decode(WebsitePayload.self, forKey: .payload)
        } else {
            // Unrelated health/manual record formats must not break provider imports.
            payload = try JSONDecoder().decode(WebsitePayload.self, from: Data("{}".utf8))
        }
    }
    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
struct WebsitePayload: Decodable {
    let name: String?; let sport: String?; let minutes: Double?; let distanceKm: Double?
    let kcal: Double?; let protein: Double?; let carbs: Double?; let fat: Double?
    let calories: Double?; let averageHR: Double?; let maxHR: Double?; let notes: String?
    let exercises: [WebsiteExercise]?; let samples: [WebsiteSample]?
    var trainingDetail: String {
        let exercises = (exercises ?? []).map { exercise in
            (exercise.title ?? "Ejercicio") + "\n" + (exercise.sets ?? []).enumerated().map { index, set in
                var values: [String] = []
                if let reps = set.reps { values.append("\(Int(reps)) reps") }
                if let kg = set.weight_kg { values.append("\(kg.formatted()) kg") }
                if let seconds = set.duration_seconds { values.append("\(Int(seconds)) s") }
                if let meters = set.distance_meters { values.append("\(Int(meters)) m") }
                return "\(index + 1)- " + values.joined(separator: " · ")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return [exercises, notes ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
struct WebsiteExercise: Decodable { let title: String?; let sets: [WebsiteSet]? }
struct WebsiteSet: Decodable { let reps: Double?; let weight_kg: Double?; let duration_seconds: Double?; let distance_meters: Double? }
struct WebsiteSample: Decodable { let seconds: Double; let hr: Double?; let latlng: [Double]? }

// Presentation-only grouping: imported originals remain intact.
enum SessionDeduplication {
    static func grouped(_ records: [Session]) -> [Session] {
        let ordered = records.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) > rank(b) }
            if a.date != b.date { return a.date < b.date }
            return a.id < b.id
        }
        var groups: [[Session]] = []
        for item in ordered {
            if let index = groups.firstIndex(where: { group in group.contains(where: { $0.id == item.id }) || group.allSatisfy { sameWorkout($0, item) } }) { groups[index].append(item) }
            else { groups.append([item]) }
        }
        return groups.map { group in
            var chosen = group[0]
            // Fill missing fields only; never sum copies or replace the chosen timing.
            for other in group.dropFirst() {
                if chosen.distance == nil { chosen.distance = other.distance }
                if chosen.calories == nil { chosen.calories = other.calories }
                if chosen.averageHR == nil { chosen.averageHR = other.averageHR }
                if chosen.maximumHR == nil { chosen.maximumHR = other.maximumHR }
                if other.detail.count > chosen.detail.count { chosen.detail = other.detail }
                if chosen.title == chosen.sport && other.title != other.sport { chosen.title = other.title }
            }
            return chosen
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    private static func generic(_ value: String) -> Bool { ["actividad", "workout", "other"].contains(value.lowercased()) }
    private static func rank(_ session: Session) -> Int {
        (generic(session.sport) ? 0 : 100) + (session.source.hasPrefix("Salud") ? 20 : 0) + (session.averageHR != nil ? 4 : 0) + (session.calories != nil ? 2 : 0) + (session.distance != nil ? 1 : 0)
    }
    static func sameWorkout(_ a: Session, _ b: Session) -> Bool {
        if a.id == b.id { return true }
        guard a.sport == b.sport || generic(a.sport) || generic(b.sport) else { return false }
        guard a.minutes.isFinite, b.minutes.isFinite, a.minutes > 0, b.minutes > 0 else { return false }
        let delta = abs(a.date.timeIntervalSince(b.date))
        guard delta <= 60 else { return false }
        let sameSource = (a.recordingSource ?? a.source) == (b.recordingSource ?? b.source)
        if let externalA = a.externalIdentifier, let externalB = b.externalIdentifier, externalA == externalB, sameSource { return true }
        // Distinct entries from the same recorder need effectively identical starts.
        guard !sameSource || delta <= 3 else { return false }
        let endA = a.recordedEnd ?? a.date.addingTimeInterval(a.minutes * 60)
        let endB = b.recordedEnd ?? b.date.addingTimeInterval(b.minutes * 60)
        let lengthA = endA.timeIntervalSince(a.date), lengthB = endB.timeIntervalSince(b.date)
        guard lengthA > 0, lengthB > 0 else { return false }
        let overlap = min(endA, endB).timeIntervalSince(max(a.date, b.date))
        guard overlap / min(lengthA, lengthB) >= 0.8 else { return false }
        // Large disagreements stay separate. Paused time and generic sport labels may differ.
        guard min(lengthA, lengthB) / max(lengthA, lengthB) >= 0.65 else { return false }
        if let da = a.distance, let db = b.distance, da > 0, db > 0 {
            guard abs(da - db) <= max(100, max(da, db) * 0.08) else { return false }
        }
        return true
    }
}
