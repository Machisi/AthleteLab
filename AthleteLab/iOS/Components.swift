import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

typealias ViewState<Value> = SwiftUI.State<Value>

enum LabPalette {
    static let coral = Color(red: 1, green: 107.0 / 255, blue: 94.0 / 255)
    static let ink = Color(red: 0.12, green: 0.06, blue: 0.05)
    static let accent = adaptive(UIColor(red: 0.69, green: 0.19, blue: 0.15, alpha: 1), UIColor(red: 1, green: 107.0 / 255, blue: 94.0 / 255, alpha: 1))
    static let canvas = adaptive(UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1), .black)
    static let surface = adaptive(.white, UIColor(white: 0.11, alpha: 1))
    static let outline = adaptive(UIColor.black.withAlphaComponent(0.07), UIColor.white.withAlphaComponent(0.10))
    static let protein = adaptive(.systemTeal, .systemMint)
    static let carbohydrates = adaptive(.systemIndigo, UIColor(red: 0.68, green: 0.68, blue: 1, alpha: 1))
    static let fats = adaptive(UIColor(red: 0.57, green: 0.32, blue: 0.06, alpha: 1), .systemYellow)

    private static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    static func sport(_ name: String) -> Color {
        switch name {
        case "Natación": protein
        case "Ciclismo": carbohydrates
        case "Fuerza": fats
        default: accent
        }
    }
}

struct LabActionStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? LabPalette.ink : LabPalette.accent)
            .background(prominent ? LabPalette.coral : LabPalette.accent.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
    }
}

struct SportIcon: View {
    let session: Session
    var body: some View {
        let color = LabPalette.sport(session.sport)
        Image(systemName: session.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    var stretch = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .padding(16)
            .background(LabPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(LabPalette.outline).allowsHitTesting(false) }
    }
}
struct MetricGrid: View {
    @EnvironmentObject var m: Model
    var body: some View { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { ForEach(m.metrics) { x in Card { Label(x.id, systemImage: x.symbol).font(.caption).foregroundStyle(.secondary); Text(x.value.formatted(.number.precision(.fractionLength(1)))).font(.title.bold()); Text(x.unit).font(.caption).foregroundStyle(.secondary) } } } }
}
struct SessionRow: View {
    var session: Session
    var body: some View {
        Card {
            HStack(spacing: 12) {
                SportIcon(session: session)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.headline)
                    Text(session.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { metrics }
                VStack(alignment: .leading, spacing: 8) { metrics }
            }.font(.subheadline.weight(.semibold)).monospacedDigit()
        }.foregroundStyle(.primary)
    }

    @ViewBuilder private var metrics: some View {
        if let distance = session.distance, distance > 0 {
            Label((distance / 1_000).formatted(.number.precision(.fractionLength(0...2))) + " km", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .fixedSize()
        }
        Label(Duration.seconds(max(0, session.minutes * 60)).formatted(.time(pattern: session.minutes >= 60 ? .hourMinuteSecond : .minuteSecond)), systemImage: "stopwatch")
            .fixedSize()
        if let heart = session.averageHR {
            Label("\(Int(heart)) ppm", systemImage: "heart").fixedSize()
        } else if let calories = session.calories {
            Label("\(Int(calories)) kcal", systemImage: "flame").fixedSize()
        }
    }
}

struct SummaryRingCard: View {
    let title: String
    let value: String
    let unit: String
    let progress: Double?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 7) {
            Text(title).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.8)
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 11)
                Circle().trim(from: 0, to: min(max(progress ?? 0, 0), 1))
                    .stroke(AngularGradient(colors: [color.opacity(0.65), color], center: .center), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.title2.weight(.medium)).foregroundStyle(color).accessibilityHidden(true)
            }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 74).padding(7)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: progress)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(minHeight: 28)
        }.padding(16).frame(maxWidth: .infinity).background(LabPalette.surface, in: RoundedRectangle(cornerRadius: 26))
        .accessibilityElement(children: .combine)
    }
}

struct RecordedActivityCard: View {
    let session: Session
    var heart: [HeartPoint] = []
    private var sportColor: Color { LabPalette.sport(session.sport) }
    var pace: String {
        guard let distance = session.distance, distance > 0, session.minutes > 0 else { return "—" }
        if session.sport == "Ciclismo" { return (distance / 1000 / (session.minutes / 60)).formatted(.number.precision(.fractionLength(1))) + " km/h" }
        let seconds = Int(session.minutes * 60 / (distance / (session.sport == "Natación" ? 100 : 1000)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60) + (session.sport == "Natación" ? " /100 m" : " /km")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(session.sport.uppercased()).font(.caption2.bold()).padding(.horizontal, 12).padding(.vertical, 7).foregroundStyle(sportColor).background(sportColor.opacity(0.12), in: Capsule())
                Spacer(); SportIcon(session: session)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(.title2.bold())
                Text(session.date.formatted(.dateTime.day().month().hour().minute())).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                metric("Distancia", value: session.distance.map { ($0 / 1000).formatted(.number.precision(.fractionLength(2))) + " km" } ?? "—")
                Spacer(); metric("Tiempo", value: duration)
            }
            if !heart.isEmpty {
                Chart(Array(heart.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Minuto", p.seconds / 60), y: .value("HR", p.bpm)).foregroundStyle(sportColor)
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false)).frame(height: 55)
                Text("Pulsaciones durante el entrenamiento").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top) {
                metric(session.sport == "Ciclismo" ? "Velocidad media" : "Ritmo medio", value: pace)
                Spacer(); metric("HR media", value: session.averageHR.map { "\(Int($0)) ppm" } ?? "—")
            }
            HStack {
                Label(session.calories.map { "\(Int($0)) kcal" } ?? "Calorías no disponibles", systemImage: "flame.fill").font(.caption)
            }.foregroundStyle(.secondary)
        }.padding(18).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
        .background(LabPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(LabPalette.outline).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }
    private var duration: String {
        let seconds = max(0, Int(session.minutes * 60))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) }
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
                            Text("\(step.number)-").font(.subheadline.bold().monospacedDigit()).foregroundStyle(LabPalette.accent).frame(width: 32, alignment: .leading)
                            Text(step.text).font(.body).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 16)
                        if index < content.steps.count - 1 { Divider() }
                    }
                }.padding(.horizontal, 20).background(LabPalette.surface, in: RoundedRectangle(cornerRadius: 24))
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
