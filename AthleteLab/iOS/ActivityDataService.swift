import Foundation
import HealthKit
import CoreLocation

extension Model {
    func relatedSamples(_ type: HKSampleType, workout: HKWorkout) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            health.execute(HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForObjects(from: workout), limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? []) }
            })
        }
    }
    func routePoints(_ route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            let buffer = RouteBuffer()
            health.execute(HKWorkoutRouteQuery(route: route) { _, values, done, error in
                buffer.lock.lock(); defer { buffer.lock.unlock() }
                guard !buffer.finished else { return }
                if let error { buffer.finished = true; continuation.resume(throwing: error); return }
                buffer.values += values ?? []
                if done { buffer.finished = true; continuation.resume(returning: buffer.values) }
            })
        }
    }
    func workoutHeart(_ workout: HKWorkout) async throws -> (points: [HeartPoint], source: String?) {
        var samples = try await relatedSamples(HKQuantityType(.heartRate), workout: workout).compactMap { $0 as? HKQuantitySample }
        var temporal = false
        if samples.isEmpty {
            temporal = true
            samples = try await withCheckedThrowingContinuation { c in
                health.execute(HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate), limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, data, error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: (data ?? []).compactMap { $0 as? HKQuantitySample }) }
                })
            }
        }
        let values = samples.map { sample in HeartReading(date: sample.startDate, bpm: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())), source: sample.sourceRevision.source.bundleIdentifier + "|" + (sample.device?.localIdentifier ?? sample.device?.name ?? "")) }
        let selected = HeartTimeline.select(values, start: workout.startDate, end: workout.endDate, preferred: workout.sourceRevision.source.bundleIdentifier)
        let points = selected.map { HeartPoint(seconds: $0.date.timeIntervalSince(workout.startDate), bpm: $0.bpm) }
        let source = samples.first { sample in selected.first?.source.hasPrefix(sample.sourceRevision.source.bundleIdentifier + "|") == true }?.sourceRevision.source.name
        return (points, points.isEmpty ? nil : (temporal ? "Salud · \(source ?? "Sensor") · muestras coincidentes con el horario; no vinculadas por la app original." : "Salud · \(source ?? "Sensor") · muestras asociadas al entrenamiento."))
    }
    func activityDetail(_ session: Session) async throws -> ActivityDetail {
        if session.id.hasPrefix("web-"), let detail = website.snapshot?.detail(for: session.id) { return detail }
        if session.id.hasPrefix("strava-") {
            let data = try await request("api/activities/strava/\(session.id.dropFirst(7))")
            return try JSONDecoder().decode(ActivityDetail.self, from: data)
        }
        guard session.source.hasPrefix("Salud"), let id = UUID(uuidString: session.id) else {
            return ActivityDetail(calories: session.calories, averageHR: session.averageHR, maximumHR: session.maximumHR)
        }
        let workout: HKWorkout? = try await withCheckedThrowingContinuation { continuation in
            health.execute(HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: HKQuery.predicateForObject(with: id), limit: 1, sortDescriptors: nil) { _, data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data?.first as? HKWorkout) }
            })
        }
        guard let workout else { return ActivityDetail() }
        let reading = try await workoutHeart(workout)
        let heart = reading.points
        var coordinates: [CLLocation] = []
        if session.sport == "Carrera" || session.sport == "Ciclismo" {
            let routes = (try? await relatedSamples(HKSeriesType.workoutRoute(), workout: workout))?.compactMap { $0 as? HKWorkoutRoute } ?? []
            for route in routes { coordinates += (try? await routePoints(route)) ?? [] }
        }
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let avg = workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        return ActivityDetail(heartSource: reading.source, calories: energy ?? session.calories, averageHR: avg ?? (heart.isEmpty ? nil : heart.reduce(0) { $0 + $1.bpm } / Double(heart.count)), maximumHR: heart.map(\.bpm).max() ?? session.maximumHR, heart: heart, route: coordinates.sorted { $0.timestamp < $1.timestamp }.map { RoutePoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
    }
}
private final class RouteBuffer: @unchecked Sendable {
    let lock = NSLock()
    var values: [CLLocation] = []
    var finished = false
}

extension Model {
    // A night is attributed to the day on which the person wakes up.
    func readNight(for day: Date) async {
        let calendar = Calendar.current
        let morning = calendar.startOfDay(for: day)
        let start = calendar.date(byAdding: .hour, value: -6, to: morning)!
        let end = min(calendar.date(byAdding: .hour, value: 12, to: morning)!, Date.now)
        guard start < end else { nightSleepHours = nil; nightDate = day; return }
        do {
            let values: [HKSample] = try await withCheckedThrowingContinuation { c in
                health.execute(HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: end), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, data, error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? []) }
                })
            }
            let sleep = values.compactMap { $0 as? HKCategorySample }.filter { [1,3,4,5].contains($0.value) }
            let source = sleep.max { $0.endDate < $1.endDate }?.sourceRevision.source.bundleIdentifier
            let intervals = sleep.filter { $0.sourceRevision.source.bundleIdentifier == source }.map { DateInterval(start: max($0.startDate, start), end: min($0.endDate, end)) }
            let hours = DashboardMath.mergedHours(intervals)
            guard calendar.isDate(day, inSameDayAs: selectedDay) else { return }
            nightSleepHours = hours > 0 ? hours : nil; nightDate = day
        } catch {
            guard calendar.isDate(day, inSameDayAs: selectedDay) else { return }
            nightSleepHours = nil; nightDate = day
        }
    }
}
