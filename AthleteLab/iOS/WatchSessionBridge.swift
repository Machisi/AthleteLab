import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

extension Model: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended { Task { @MainActor in liveHeart = nil; mirrored = nil } }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) { Task { @MainActor in message = error.localizedDescription } }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        guard let last = data.last, let value = try? JSONDecoder().decode(Double.self, from: last) else { return }
        Task { @MainActor in liveHeart = value }
    }
}
