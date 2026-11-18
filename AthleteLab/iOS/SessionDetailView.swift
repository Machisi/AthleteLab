import SwiftUI
import Charts
import MapKit

struct SessionDetail: View {
    @EnvironmentObject var m: Model
    let session: Session
    @ViewState private var data = ActivityDetail()
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var heartStyle = "range"
    var isPlan: Bool { session.source == "Calendario Athlete Lab" || session.source == "Plan personal" }
    var enrichedSession: Session {
        var value = session; value.calories = data.calories ?? session.calories; value.averageHR = data.averageHR ?? session.averageHR
        return value
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            if !isPlan { RecordedActivityCard(session: enrichedSession, heart: data.heart) }
            else {
                Label(session.sport, systemImage: session.symbol).foregroundStyle(.secondary)
                Text(session.date.formatted(.dateTime.day().month(.wide).year().hour().minute())).font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    stat("Distancia", value: session.distance.map { ($0 / 1000).formatted(.number.precision(.fractionLength(2))) + " km" } ?? "—", icon: "point.topleft.down.to.point.bottomright.curvepath")
                    stat("Tiempo", value: "\(Int(session.minutes)) min", icon: "stopwatch")
                }
            }
            if !isPlan {
                Card {
                    Label("Frecuencia cardiaca", systemImage: "heart.fill").font(.headline).foregroundStyle(.red)
                    if let low = data.heart.map(\.bpm).min(), let high = data.maximumHR ?? data.heart.map(\.bpm).max() { Text("\(Int(low))–\(Int(high)) ppm").font(.title.bold()) }
                    if loading { ProgressView("Leyendo actividad…") }
                    else if data.heart.isEmpty { Text("No hay pulsaciones disponibles. Revisa en Salud el permiso de frecuencia cardiaca para Athlete Lab y comprueba que existan muestras durante esta sesión.").foregroundStyle(.secondary) }
                    else {
                        Picker("Gráfica", selection: $heartStyle) { Text("Rangos").tag("range"); Text("Curva").tag("line") }.pickerStyle(.segmented)
                        HeartChart(points: data.heart, ranges: heartStyle == "range")
                        Text("Pulsaciones a lo largo de la sesión · minutos transcurridos").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let source = data.heartSource { Text(source).font(.caption).foregroundStyle(.secondary) }
                if session.sport == "Carrera" || session.sport == "Ciclismo" {
                    Card {
                        Label("Recorrido", systemImage: "map.fill").font(.headline)
                        if !data.route.isEmpty {
                            Map { MapPolyline(coordinates: data.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }).stroke(LabPalette.coral, lineWidth: 4) }
                                .frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityLabel("Mapa del recorrido registrado")
                        } else { Text("El recorrido aparecerá si la actividad incluye GPS y has autorizado su lectura.").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            if isPlan { TrainingInstructionView(session: session) }
            else { Card { Text("Detalles").font(.title2.bold()); Text(session.detail).textSelection(.enabled) } }
            if !isPlan { Text("Origen: \(session.source)").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).padding(.bottom, 12) }.background(LabPalette.canvas)
        .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            guard !isPlan else { return }; loading = true; defer { loading = false }
            do { data = try await m.activityDetail(session) } catch { self.error = error.localizedDescription }
        }
    }
    func stat(_ title: String, value: String, icon: String) -> some View {
        Card { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()).minimumScaleFactor(0.7).lineLimit(1) }
    }
}
struct HeartRange: Identifiable { let minute: Int; let low: Double; let high: Double; var id: Int { minute } }
struct HeartChart: View {
    let points: [HeartPoint]
    var ranges: Bool
    var bins: [HeartRange] {
        Dictionary(grouping: points, by: { Int($0.seconds / 60) }).map { key, values in HeartRange(minute: key, low: values.map(\.bpm).min()!, high: values.map(\.bpm).max()!) }.sorted { $0.minute < $1.minute }
    }
    var body: some View {
        let baseline = max(0, (points.map(\.bpm).min() ?? 0) - 10)
        let ceiling = (points.map(\.bpm).max() ?? 1) + 10
        Chart {
            if ranges {
                ForEach(bins) { b in
                    if b.high > b.low {
                        BarMark(x: .value("Minuto", b.minute), yStart: .value("Mínima", b.low), yEnd: .value("Máxima", b.high), width: .ratio(0.65)).cornerRadius(8).foregroundStyle(LabPalette.accent)
                    } else { PointMark(x: .value("Minuto", b.minute), y: .value("HR", b.low)).foregroundStyle(.red).symbolSize(16) }
                }
            } else {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("Minuto", p.seconds / 60), yStart: .value("Base", baseline), yEnd: .value("HR", p.bpm)).foregroundStyle(.linearGradient(colors: [.red.opacity(0.25), .red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Minuto", p.seconds / 60), y: .value("HR", p.bpm)).foregroundStyle(.red)
                }
            }
        }.chartYScale(domain: baseline...ceiling).frame(height: 200)
    }
}
