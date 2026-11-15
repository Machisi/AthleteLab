"""Compile and test the actual grouping code, with fixtures isolated from the iPhone target."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'iOS/Models.swift').read_text()
entities = source[source.index('struct Session:'):source.index('struct Metric:')]
logic = source[source.index('// Presentation-only grouping:'):]
tests = r'''
let start = ISO8601DateFormatter().date(from: "2026-11-13T06:41:00Z")!
func item(_ id: String, _ sport: String, _ minutes: Double, _ offset: Double = 0, _ source: String = "Salud · Watch", _ distance: Double? = nil) -> Session {
    Session(id: id, title: sport, sport: sport, date: start.addingTimeInterval(offset), minutes: minutes, distance: distance, source: source, detail: "", calories: id == "strength" ? 222 : 181)
}
let strength = item("strength", "Fuerza", 42 + 55.0/60, 0, "Salud · Hevy")
let generic = item("generic", "Actividad", 30 + 35.0/60, 20)
let one = SessionDeduplication.grouped([generic, strength])
precondition(one.count == 1 && one[0].id == "strength" && one[0].calories == 222)
precondition(one[0].minutes == strength.minutes)
let bike = item("bike", "Ciclismo", 60, 7200, "Salud · iGPS", 25000)
let bikeCopy = item("bike-copy", "Ciclismo", 58, 7225, "Strava", 25100)
let grouped = SessionDeduplication.grouped([strength, generic, bike, bikeCopy])
precondition(grouped.count == 2)
precondition(grouped.compactMap(\.distance).reduce(0,+) == 25000)
precondition(SessionDeduplication.grouped([bike, bike]).count == 1)
precondition(SessionDeduplication.grouped([strength, item("later", "Fuerza", 43, 7200)]).count == 2)
precondition(SessionDeduplication.grouped([item("run", "Carrera", 40), item("ride", "Ciclismo", 40)]).count == 2)
precondition(SessionDeduplication.grouped([item("short", "Ciclismo", 15), item("long", "Ciclismo", 80, 0, "Strava")]).count == 2)
precondition(SessionDeduplication.grouped([item("a", "Ciclismo", 60, 0, "A", 20000), item("b", "Ciclismo", 60, 0, "B", 100000)]).count == 2)
precondition(SessionDeduplication.grouped([item("same-a", "Fuerza", 40), item("same-b", "Fuerza", 40, 30)]).count == 2)
var paused = item("pause", "Fuerza", 30, 0, "Hevy"); paused.recordedEnd = start.addingTimeInterval(3600)
var elapsed = item("elapsed", "Fuerza", 60, 0, "Salud · Watch"); elapsed.recordedEnd = paused.recordedEnd
precondition(SessionDeduplication.grouped([paused, elapsed]).count == 1)
let multi = [item("run", "Carrera", 40, 0, "Run"), item("ride", "Ciclismo", 40, 0, "Bike"), item("other", "Actividad", 40, 0, "Other")]
precondition(SessionDeduplication.grouped(multi).count == 2)
let expected = grouped.map(\.id)
for _ in 0..<20 { precondition(SessionDeduplication.grouped([strength, generic, bike, bikeCopy].shuffled()).map(\.id) == expected) }
print("PASS: captura fuerza/actividad, bici, totales, pausas, identidad, estabilidad y sesiones distintas conservadas.")
'''
with tempfile.TemporaryDirectory(prefix='athlete-dedup-tests-') as directory:
    path = Path(directory)
    (path/'main.swift').write_text('import Foundation\n'+entities+'\n'+logic+'\n'+tests)
    subprocess.run(['swiftc','-module-cache-path',str(path/'modules'),str(path/'main.swift'),'-o',str(path/'tests')],check=True)
    subprocess.run([str(path/'tests')],check=True)
