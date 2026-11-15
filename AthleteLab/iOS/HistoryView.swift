import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

struct History: View {
    @EnvironmentObject var m: Model
    var body: some View { ScrollView { VStack(spacing: 16) { if m.uniqueSessions.isEmpty { ContentUnavailableView("Aún no hay actividades", systemImage: "figure.run", description: Text("Conecta Salud, Strava o Hevy desde tu perfil.")) } else { Card { Text("Últimas sesiones").font(.headline); Chart(m.uniqueSessions.prefix(14)) { s in BarMark(x: .value("Fecha", s.date, unit: .day), y: .value("Minutos", s.minutes)).foregroundStyle(by: .value("Deporte", s.sport)) }.frame(height: 180) }; ForEach(m.uniqueSessions) { s in NavigationLink { SessionDetail(session: s) } label: { SessionRow(session: s) }.buttonStyle(.plain) } } }.padding() }.background(Color(.systemGroupedBackground)) }
}
