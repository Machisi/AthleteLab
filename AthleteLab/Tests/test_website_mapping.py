"""Run the actual Swift website DTO/mapping code with isolated fixtures; never bundled in the app."""
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
source = (project / 'iOS/Models.swift').read_text()
parts = [source[source.index('struct Session:'):source.index('struct Metric:')], source[source.index('struct HeartPoint:'):source.index('struct WeightPoint:')], source[source.index('// Wire format of the existing'):]]
tests = r'''
let raw = #"""
{"providers":{"fatsecret":{"configured":true,"connected":true},"hevy":{"configured":true,"connected":true,"mode":"connector"},"strava":{"configured":true,"connected":true}},"records":[
{"id":"food:1","source":"fatsecret","category":"food","occurred":"2026-11-14","payload":{"name":"Alimento A","kcal":240,"protein":12,"carbs":30,"fat":8}},
{"id":"food:1","source":"fatsecret","category":"food","occurred":"2026-11-14","payload":{"name":"Duplicado","kcal":240}},
{"id":"food:2","source":"fatsecret","category":"food","occurred":"2026-11-13","payload":{"name":"Otro día","kcal":100}},
{"id":"food:3","source":"manual","category":"food","occurred":"2026-11-14","payload":{"kcal":999,"samples":"unrelated-record-format"}},
{"id":"hevy:1","source":"hevy","category":"workout","occurred":"2026-11-14T06:00:00.123Z","payload":{"name":"Fuerza","sport":"strength","minutes":35,"exercises":[{"title":"Remo","sets":[{"reps":10,"weight_kg":30}]}]}},
{"id":"strava:1","source":"strava","category":"workout","occurred":"2026-11-14T08:00:00Z","payload":{"name":"Carrera","sport":"run","minutes":40,"distanceKm":7.5,"averageHR":140,"maxHR":160,"samples":[{"seconds":0,"hr":135,"latlng":[39.4,-0.3]},{"seconds":1,"hr":145,"latlng":[999,0]}]}}
]}
"""#
let data = try JSONDecoder().decode(WebsiteSnapshot.self, from: Data(raw.utf8))
var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
let day = WebsiteRecord.date("2026-11-14T12:00:00Z")!
let meals = data.meals(on: day, calendar: calendar)
precondition(meals.count == 1 && meals[0].calories == 240 && meals[0].protein == 12)
precondition(data.meals(on: WebsiteRecord.date("2026-11-15T12:00:00Z")!, calendar: calendar).isEmpty)
let sessions = data.sessions
precondition(sessions.count == 2)
precondition(sessions.first(where: {$0.sport == "Carrera"})?.distance == 7500)
precondition(sessions.first(where: {$0.sport == "Fuerza"})!.detail.contains("10 reps"))
let detail = data.detail(for: "web-strava:1")!
precondition(detail.heart.count == 2 && detail.route.count == 1)
precondition(data.detail(for: "web-hevy:1")?.heartSource == nil)
let denied = raw.replacingOccurrences(of: "\"connected\":true", with: "\"connected\":false")
let disconnected = try JSONDecoder().decode(WebsiteSnapshot.self, from: Data(denied.utf8))
precondition(disconnected.sessions.isEmpty && disconnected.meals(on: day, calendar: calendar).isEmpty)
print("PASS: fecha local, alimentos, macros, duplicados, unidades, series Hevy, HR, GPS y desconexión.")
'''
with tempfile.TemporaryDirectory(prefix='athlete-web-tests-') as directory:
    path = Path(directory)
    swift = path / 'main.swift'
    swift.write_text('import Foundation\n' + '\n'.join(parts) + '\n' + tests)
    subprocess.run(['swiftc', '-module-cache-path', str(path/'modules'), str(swift), '-o', str(path/'tests')], check=True)
    subprocess.run([str(path/'tests')], check=True)
