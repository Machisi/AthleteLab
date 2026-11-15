"""Exercise actual Swift diary totals, compatibility, grouping and goal arithmetic."""
from pathlib import Path
import subprocess, tempfile
source = (Path(__file__).resolve().parents[1] / 'iOS/Models.swift').read_text()
model = source[source.index('struct Meal:'):source.index('struct Metric:')]
tests = r'''
let raw = #"[{"id":"1","title":"Pan","calories":200,"protein":10,"carbs":30,"fat":4,"mealType":"breakfast","servingDescription":"2 rebanadas"},{"id":"2","title":"Leche","calories":50,"protein":3,"carbs":5,"fat":2,"mealType":"Breakfast"},{"id":"3","title":"Comida","calories":400,"protein":20,"carbs":50,"fat":10,"mealType":"lunch"},{"id":"4","title":"Cena","calories":300,"protein":30,"carbs":20,"fat":12,"mealType":"dinner"},{"id":"5","title":"Sin clasificar","calories":100,"protein":5,"carbs":10,"fat":3}]"#
let meals = try JSONDecoder().decode([Meal].self, from: Data(raw.utf8))
precondition(meals[4].category == .other)
precondition(meals[0].servingDescription == "2 rebanadas")
let breakfast = NutritionTotals(meals.filter { $0.category == .breakfast })
precondition(breakfast.calories == 250 && breakfast.protein == 13)
let totals = NutritionTotals(meals)
let grouped = MealCategory.allCases.map { NutritionTotals(meals.filter { $0.category == $0.category }) }
precondition(totals.calories == 1050 && totals.protein == 68 && totals.carbs == 115 && totals.fat == 31)
precondition(NutritionTotals([]).calories == 0)
precondition(NutritionTotals.progress(1207, toward: 2400)! > 0.5)
precondition(NutritionTotals.progress(92, toward: 120)! > 0.76)
precondition(NutritionTotals.progress(1207, toward: 0) == nil)
precondition(NutritionTotals.progress(0, toward: 100) == 0)
precondition(NutritionTotals.progress(110, toward: 100) == 1)
precondition(NutritionTotals.progress(10, toward: .nan) == nil)
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
defer { try? FileManager.default.removeItem(at: file) }
let cache = NutritionDiaryCache(file: file, capacity: 2)
precondition(cache.meals(for: "2026-11-13") == nil)
cache.save(meals, for: "2026-11-13", now: Date(timeIntervalSince1970: 1))
precondition(NutritionDiaryCache(file: file).meals(for: "2026-11-13")?.count == 5)
cache.save([], for: "2026-11-14", now: Date(timeIntervalSince1970: 2))
precondition(cache.meals(for: "2026-11-14")?.isEmpty == true)
cache.save([meals[0]], for: "2026-11-15", now: Date(timeIntervalSince1970: 3))
precondition(cache.meals(for: "2026-11-13") == nil)
precondition(cache.meals(for: "2026-11-15")?.first?.calories == 200)
cache.removeAll()
precondition(NutritionDiaryCache(file: file).meals(for: "2026-11-15") == nil)
var madrid = Calendar(identifier: .gregorian); madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
let late = ISO8601DateFormatter().date(from: "2026-11-14T23:30:00Z")!
precondition(NutritionDiaryCache.dayKey(late, calendar: madrid) == "2026-11-15")
print("PASS: macros, progreso, caché persistente, días vacíos, capacidad, desconexión y fecha local.")
'''
# Group subtotal sum must always agree with the daily total.
tests=tests.replace('let grouped = MealCategory.allCases.map { NutritionTotals(meals.filter { $0.category == $0.category }) }','let grouped = MealCategory.allCases.map { category in NutritionTotals(meals.filter { $0.category == category }) }\nprecondition(grouped.reduce(0) { $0 + $1.calories } == totals.calories)')
with tempfile.TemporaryDirectory(prefix='athlete-nutrition-tests-') as d:
    p=Path(d); (p/'main.swift').write_text('import Foundation\n'+model+'\n'+tests)
    subprocess.run(['swiftc','-module-cache-path',str(p/'modules'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
