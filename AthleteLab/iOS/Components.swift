import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

typealias ViewState<Value> = SwiftUI.State<Value>

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 16) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24)) }
}
struct MetricGrid: View {
    @EnvironmentObject var m: Model
    var body: some View { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { ForEach(m.metrics) { x in Card { Label(x.id, systemImage: x.symbol).font(.caption).foregroundStyle(.secondary); Text(x.value.formatted(.number.precision(.fractionLength(1)))).font(.title.bold()); Text(x.unit).font(.caption).foregroundStyle(.secondary) } } } }
}
struct SessionRow: View {
    var session: Session
    var body: some View { RecordedActivityCard(session: session) }
}

struct SummaryRingCard: View {
    let title: String
    let value: String
    let unit: String
    let progress: Double?
    let color: Color
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.8)
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 11)
                Circle().trim(from: 0, to: min(max(progress ?? 0, 0), 1))
                    .stroke(AngularGradient(colors: [color.opacity(0.65), color], center: .center), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 40, weight: .medium)).foregroundStyle(color).accessibilityHidden(true)
            }.aspectRatio(1, contentMode: .fit).padding(9)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(minHeight: 28)
        }.padding(16).frame(maxWidth: .infinity).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
        .accessibilityElement(children: .combine)
    }
}

struct RecordedActivityCard: View {
    let session: Session
    var heart: [HeartPoint] = []
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    var pace: String {
        guard let distance = session.distance, distance > 0, session.minutes > 0 else { return "—" }
        if session.sport == "Ciclismo" { return (distance / 1000 / (session.minutes / 60)).formatted(.number.precision(.fractionLength(1))) + " km/h" }
        let seconds = Int(session.minutes * 60 / (distance / (session.sport == "Natación" ? 100 : 1000)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60) + (session.sport == "Natación" ? " /100 m" : " /km")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(session.sport.uppercased()).font(.caption2.bold()).padding(.horizontal, 12).padding(.vertical, 7).background(.white.opacity(0.12), in: Capsule())
                Spacer(); Image(systemName: session.symbol).font(.title2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(.title2.bold())
                Text(session.date.formatted(.dateTime.day().month().hour().minute())).font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
            HStack(alignment: .top) {
                metric("Distancia", value: session.distance.map { ($0 / 1000).formatted(.number.precision(.fractionLength(2))) + " km" } ?? "—")
                Spacer(); metric("Tiempo", value: duration)
            }
            if !heart.isEmpty {
                Chart(Array(heart.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Minuto", p.seconds / 60), y: .value("HR", p.bpm)).foregroundStyle(.white.opacity(0.85))
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false)).frame(height: 55)
                Text("Pulsaciones durante el entrenamiento").font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
            Divider().overlay(.white.opacity(0.2))
            HStack(alignment: .top) {
                metric(session.sport == "Ciclismo" ? "Velocidad media" : "Ritmo medio", value: pace)
                Spacer(); metric("HR media", value: session.averageHR.map { "\(Int($0)) ppm" } ?? "—")
            }
            HStack {
                Label(session.calories.map { "\(Int($0)) kcal" } ?? "Calorías no disponibles", systemImage: "flame.fill").font(.caption)
                Spacer(); Image(systemName: "arrow.up.right").font(.subheadline.bold())
            }.foregroundStyle(.white.opacity(0.8))
        }.padding(24).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .trailing) {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: session.symbol).resizable().scaledToFit().frame(width: 230, height: 270).rotationEffect(.degrees(-12)).foregroundStyle(.white.opacity(0.09)).offset(x: 50, y: 20).blur(radius: reduceTransparency ? 0 : 2)
                if !reduceTransparency { Rectangle().fill(.ultraThinMaterial).opacity(0.12) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
    private var duration: String {
        let seconds = max(0, Int(session.minutes * 60))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.white.opacity(0.65)); Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) }
    }
}

struct TrainingInstructionView: View {
    let session: Session
    var content: TrainingText { TrainingText(session.detail) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !content.steps.isEmpty {
                Text(session.sport == "Fuerza" ? "Ejercicios" : "Bloques de la sesión").font(.title2.bold())
                VStack(spacing: 0) {
                    ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(step.number)-").font(.subheadline.bold().monospacedDigit()).foregroundStyle(.orange).frame(width: 32, alignment: .leading)
                            Text(step.text).font(.body).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 16)
                        if index < content.steps.count - 1 { Divider() }
                    }
                }.padding(.horizontal, 20).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            }
            if !content.notes.isEmpty {
                Card {
                    Label("Indicaciones", systemImage: "info.circle").font(.headline)
                    ForEach(Array(content.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }.textSelection(.enabled)
    }
}
