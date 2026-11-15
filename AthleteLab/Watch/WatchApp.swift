import SwiftUI
import HealthKit

@MainActor final class Recorder: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    let health = HKHealthStore()
    @Published var running = false
    @Published var heart = 0.0
    @Published var message = "Listo para entrenar"
    var session: HKWorkoutSession?
    var builder: HKLiveWorkoutBuilder?
    func start(_ type: HKWorkoutActivityType) async {
        do {
            let hr = HKQuantityType.quantityType(forIdentifier: .heartRate)!
            try await health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hr])
            let config = HKWorkoutConfiguration(); config.activityType = type; config.locationType = type == .swimming ? .indoor : .outdoor
            if type == .swimming { config.swimmingLocationType = .pool; config.lapLength = HKQuantity(unit: .meter(), doubleValue: 25) }
            let workout = try HKWorkoutSession(healthStore: health, configuration: config)
            let live = workout.associatedWorkoutBuilder(); live.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            session = workout; builder = live; workout.delegate = self; live.delegate = self
            workout.startActivity(with: .now)
            try await live.beginCollection(at: .now); running = true; message = "Grabando en el reloj"
            workout.startMirroringToCompanionDevice { _, _ in }
        } catch { message = error.localizedDescription }
    }
    func stop() { session?.end() }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in
            do { try await builder?.endCollection(at: date); _ = try await builder?.finishWorkout(); message = "Guardado en Salud" } catch { message = error.localizedDescription }
            running = false
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) { Task { @MainActor in message = error.localizedDescription; running = false } }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hr = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        guard collectedTypes.contains(hr), let value = workoutBuilder.statistics(for: hr)?.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) else { return }
        Task { @MainActor in heart = value; if let data = try? JSONEncoder().encode(value) { session?.sendToRemoteWorkoutSession(data: data) { _, _ in } } }
    }
}
@main struct AthleteLabWatch: App {
    @StateObject var recorder = Recorder()
    var body: some Scene { WindowGroup { ScrollView { VStack(spacing: 12) {
        Text("ATHLETE LAB").font(.caption).foregroundStyle(.blue)
        if recorder.running { Text("\(Int(recorder.heart))").font(.system(size: 48, weight: .bold, design: .rounded)); Text("ppm").foregroundStyle(.secondary); Button("Terminar", role: .destructive) { recorder.stop() } }
        else { ForEach(["Carrera", "Ciclismo", "Natación"], id: \.self) { name in Button(name) { Task { await recorder.start(name == "Carrera" ? .running : name == "Ciclismo" ? .cycling : .swimming) } } } }
        Text(recorder.message).font(.footnote)
    } } } }
}
