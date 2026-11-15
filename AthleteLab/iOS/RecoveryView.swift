import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

struct Recovery: View {
    @EnvironmentObject var m: Model
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) { Card { Label("CONSTRUYENDO TU REFERENCIA", systemImage: "waveform.path.ecg").font(.caption.bold()).foregroundStyle(.blue); Text("Escucha tu evolución.").font(.title.bold()); Text("Tus mediciones reales aparecen aquí. Una puntuación de recuperación necesita historial suficiente y un modelo validado.").foregroundStyle(.secondary) }; MetricGrid(); Card { Text("Qué estás viendo").font(.headline); Text("Últimas mediciones disponibles en los últimos 30 días. El sueño corresponde a las últimas 24 horas. No son lecturas continuas ni un diagnóstico.").font(.subheadline).foregroundStyle(.secondary) } }.padding() }.background(Color(.systemGroupedBackground)) }
}
