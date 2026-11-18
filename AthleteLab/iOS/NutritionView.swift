import SwiftUI

struct NutritionSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meals: [Meal]
    let editGoals: () -> Void
    @AppStorage("goalCalories") var goalCalories = 0.0
    @AppStorage("goalProtein") var goalProtein = 0.0
    @AppStorage("goalCarbs") var goalCarbs = 0.0
    @AppStorage("goalFat") var goalFat = 0.0
    var totals: NutritionTotals { NutritionTotals(meals) }
    var body: some View {
        VStack(spacing: 12) {
            let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Card(stretch: !dynamicType.isAccessibilitySize) {
                    Text("CALORÍAS").font(.caption.bold()).foregroundStyle(.secondary)
                    ZStack {
                        Circle().stroke(Color(.tertiarySystemFill), lineWidth: 12)
                        Circle().trim(from: 0, to: NutritionTotals.progress(totals.calories, toward: goalCalories) ?? 0)
                            .stroke(LabPalette.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(totals.calories.formatted(.number.precision(.fractionLength(0)))).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1)
                            Text("kcal").font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 100).frame(maxWidth: .infinity).padding(6)
                    if goalCalories > 0 {
                        Text("de \(goalCalories.formatted(.number.precision(.fractionLength(0)))) kcal").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(totals.calories / goalCalories * 100))% del objetivo").font(.caption2).monospacedDigit()
                    } else {
                        Button("Fijar objetivo", action: editGoals).font(.caption.bold())
                    }
                }
                Card(stretch: !dynamicType.isAccessibilitySize) {
                    macro("PROTEÍNA", value: totals.protein, goal: goalProtein, color: LabPalette.protein)
                    macro("CARBOHIDRATOS", value: totals.carbs, goal: goalCarbs, color: LabPalette.carbohydrates)
                    macro("GRASAS", value: totals.fat, goal: goalFat, color: LabPalette.fats)
                }
            }
            if [goalCalories, goalProtein, goalCarbs, goalFat].contains(where: { $0 <= 0 }) {
                Button(action: editGoals) {
                    HStack(spacing: 10) {
                        Image(systemName: "target").font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Completa tus objetivos diarios").font(.subheadline.bold())
                            Text("Define las metas para ver el progreso del anillo y las barras.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.bold())
                    }.padding(16).background(LabPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: totals.calories)
    }
    func macro(_ name: String, value: Double, goal: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.caption2.bold()).foregroundStyle(.secondary)
            Text("\(value.formatted(.number.precision(.fractionLength(0)))) g").font(.subheadline.bold()).monospacedDigit()
            if let progress = NutritionTotals.progress(value, toward: goal) {
                ProgressView(value: progress).tint(color).accessibilityLabel(name).accessibilityValue("\(Int(progress * 100)) por ciento")
                Text("de \(goal.formatted(.number.precision(.fractionLength(0)))) g").font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Fijar meta", action: editGoals).font(.caption)
            }
        }
    }
}
struct Nutrition: View {
    let openSettings: () -> Void
    @EnvironmentObject var m: Model
    @ViewState var goals = false
    var meals: [Meal] {
        guard let day = m.mealsDay, Calendar.current.isDate(day, inSameDayAs: m.selectedDay) else { return [] }
        return m.meals
    }
    var body: some View {
        ScrollView { VStack(spacing: 16) {
            WeekStrip(selection: $m.selectedDay, marked: Set(m.plan.map { Calendar.current.startOfDay(for: $0.date) }))
            NutritionSummary(meals: meals) { goals = true }
            Text("Comidas de \(m.selectedDay.formatted(date: .abbreviated, time: .omitted))").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            if let error = m.nutritionError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if m.nutritionBusy && meals.isEmpty { ProgressView("Consultando diario…").padding() }
            ForEach(MealCategory.allCases) { category in
                MealGroupCard(category: category, meals: meals.filter { $0.category == category })
            }
            if m.connections["fatsecret"] != true && meals.isEmpty {
                Button("Configurar FatSecret", action: openSettings).buttonStyle(LabActionStyle())
            }
        }.padding(16).padding(.bottom, 12) }.background(LabPalette.canvas).refreshable { await m.refreshNutrition() }
        .toolbar { Button("Objetivos") { goals = true }.buttonStyle(LabActionStyle(prominent: false)) }.sheet(isPresented: $goals) { NutritionGoals() }
    }
}
struct MealGroupCard: View {
    let category: MealCategory
    let meals: [Meal]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var expanded = false
    var totals: NutritionTotals { NutritionTotals(meals) }
    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded.animation(reduceMotion ? nil : .easeInOut(duration: 0.22))) {
                VStack(alignment: .leading, spacing: 10) {
                    if meals.isEmpty { Text("Sin alimentos registrados").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(meals) { meal in
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(meal.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Text("\(meal.calories.formatted(.number.precision(.fractionLength(0)))) kcal").font(.subheadline.weight(.medium)).monospacedDigit().fixedSize()
                            }
                            if let serving = meal.servingDescription, !serving.isEmpty {
                                Text(serving).font(.caption).foregroundStyle(.secondary)
                            }
                            macroLine(NutritionTotals([meal]))
                        }.accessibilityElement(children: .combine)
                    }
                }.padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 9) {
                        Image(systemName: category.symbol).foregroundStyle(LabPalette.accent).accessibilityHidden(true)
                        Text(category.title).font(.headline)
                        Spacer(minLength: 2)
                        Text("\(totals.calories.formatted(.number.precision(.fractionLength(0)))) kcal").font(.subheadline.bold()).monospacedDigit()
                    }
                    macroLine(totals)
                    Text("\(meals.count) \(meals.count == 1 ? "alimento" : "alimentos")").font(.caption2).foregroundStyle(.secondary)
                }.foregroundStyle(.primary).padding(.trailing, 8).frame(minHeight: 44)
            }.tint(.secondary)
        }
    }
    func macroLine(_ value: NutritionTotals) -> some View {
        ViewThatFits(in: .horizontal) {
            Text("Proteína \(grams(value.protein)) · HC \(grams(value.carbs)) · Grasas \(grams(value.fat))")
            VStack(alignment: .leading, spacing: 4) {
                Text("Proteína \(grams(value.protein))")
                Text("HC \(grams(value.carbs)) · Grasas \(grams(value.fat))")
            }
        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    func grams(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + " g" }
}
struct NutritionGoals: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("goalCalories") var calories = 0.0
    @AppStorage("goalProtein") var protein = 0.0
    @AppStorage("goalCarbs") var carbs = 0.0
    @AppStorage("goalFat") var fat = 0.0
    var body: some View { NavigationStack { Form {
        Section {
            row("Energía · kcal", value: $calories)
            row("Proteína · g", value: $protein)
            row("Carbohidratos · g", value: $carbs)
            row("Grasas · g", value: $fat)
        } footer: {
            Text("Introduce las metas que utilizas en FatSecret. Los alimentos se importan directamente; estas metas se guardan en Athlete Lab. Un valor de 0 deja esa meta sin definir.")
        }
    }.navigationTitle("Objetivos diarios").toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark").frame(minWidth: 32, minHeight: 32) }.accessibilityLabel("Guardar objetivos") } } } }
    func row(_ title: String, value: Binding<Double>) -> some View { HStack { Text(title); Spacer(); TextField("Sin definir", value: value, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(width: 100) }.onChange(of: value.wrappedValue) { _, new in if !new.isFinite || new < 0 { value.wrappedValue = 0 } } }
}
