import SwiftUI
import Charts

struct Today: View {
    @EnvironmentObject var m: Model
    @AppStorage("weeklyKmGoal") var weeklyKmGoal = 0.0
    @AppStorage("sleepGoalHours") var sleepGoalHours = 0.0
    var dailyPlan: [Session] { m.plan.filter { Calendar.current.isDate($0.date, inSameDayAs: m.selectedDay) }.sorted { $0.date < $1.date } }
    var recorded: [Session] { m.uniqueSessions.filter { Calendar.current.isDate($0.date, inSameDayAs: m.selectedDay) } }
    var week: DateInterval { DashboardMath.week(containing: m.selectedDay) }
    var kilometres: Double { DashboardMath.kilometres(m.uniqueSessions, in: week) }
    var sleepHours: Double? { guard let date = m.nightDate, Calendar.current.isDate(date, inSameDayAs: m.selectedDay) else { return nil }; return m.nightSleepHours }
    var food: [Meal] { guard let date = m.mealsDay, Calendar.current.isDate(date, inSameDayAs: m.selectedDay) else { return [] }; return m.meals }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            WeekStrip(selection: $m.selectedDay, marked: Set(m.plan.map { Calendar.current.startOfDay(for: $0.date) }))
            HStack(alignment: .top, spacing: 12) {
                SummaryRingCard(title: "Kilómetros", value: kilometres.formatted(.number.precision(.fractionLength(1))), unit: "km esta semana", progress: weeklyKmGoal > 0 ? kilometres / weeklyKmGoal : nil, color: .orange, subtitle: weeklyKmGoal > 0 ? "Objetivo \(weeklyKmGoal.formatted()) km" : "Sin objetivo semanal", symbol: "figure.run")
                SummaryRingCard(title: "Recuperación", value: sleepHours.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", unit: "h de sueño", progress: sleepHours.flatMap { sleepGoalHours > 0 ? $0 / sleepGoalHours : nil }, color: .cyan, subtitle: sleepHours == nil ? "Sin datos nocturnos" : "Descanso registrado", symbol: "moon.zzz.fill")
            }
            Text("Lun–dom · \(week.start.formatted(.dateTime.day().month())) – \(week.end.addingTimeInterval(-1).formatted(.dateTime.day().month())) · Recuperación: el anillo refleja sueño frente a tu objetivo, no una puntuación global.").font(.caption).foregroundStyle(.secondary)
            if !food.isEmpty {
                Card {
                    Label("CALORÍAS INGERIDAS", systemImage: "fork.knife").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("\(Int(food.reduce(0) { $0 + $1.calories })) kcal").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Comidas registradas el \(m.selectedDay.formatted(.dateTime.day().month()))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let heart = m.liveHeart { Card { Label("APPLE WATCH · EN DIRECTO", systemImage: "heart.fill").foregroundStyle(.red); Text("\(Int(heart)) ppm").font(.largeTitle.bold()) } }
            HStack { Text("Tu entrenamiento").font(.title2.bold()); Spacer(); Text(m.selectedDay.formatted(.dateTime.day().month())).font(.caption).foregroundStyle(.secondary) }
            if dailyPlan.isEmpty { Card { Label("Sin sesión planificada", systemImage: "calendar"); Text("Consulta otra fecha o añade una sesión en Mi plan.").foregroundStyle(.secondary) } }
            ForEach(dailyPlan) { s in
                NavigationLink { SessionDetail(session: s) } label: {
                    Card { HStack { Image(systemName: s.symbol).foregroundStyle(.blue); Text(s.title).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.caption) }; Text(s.date.formatted(.dateTime.hour().minute()) + " · \(Int(s.minutes)) min").font(.caption).foregroundStyle(.secondary); Text(TrainingText(s.detail).preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
                }.buttonStyle(.plain)
            }
            if !recorded.isEmpty { Text("Actividad registrada").font(.title2.bold()); ForEach(recorded) { s in NavigationLink { SessionDetail(session: s) } label: { SessionRow(session: s) }.buttonStyle(.plain) } }
        }.padding() }.background(Color(.systemGroupedBackground))
        .refreshable { await m.sync() }
    }
}
