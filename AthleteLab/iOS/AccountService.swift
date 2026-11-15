import Foundation
import SwiftUI
import WebKit
import Security

enum AppConfiguration {
    // Public deployment address configured by Athlete Lab, never by the end user.
    static var apiBaseURL: String { Bundle.main.object(forInfoDictionaryKey: "AthleteLabAPIBaseURL") as? String ?? "" }
}
struct ProviderSession: Decodable { let token: String }

extension Model {
    func ensureProviderSession(force: Bool = false) async throws {
        if !force && !Vault.get("providerSession").isEmpty { return }
        if let pending = providerSessionTask { return try await pending.value }
        let task = Task { @MainActor in
            var key = Vault.get("installationKey")
            if key.isEmpty {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw URLError(.cannotCreateFile) }
                key = bytes.map { String(format: "%02x", $0) }.joined()
                try Vault.set(key, "installationKey")
            }
            let data = try await request("auth/device", method: "POST", body: ["installation_key": key])
            let session = try JSONDecoder().decode(ProviderSession.self, from: data)
            try Vault.set(session.token, "providerSession")
        }
        providerSessionTask = task
        defer { providerSessionTask = nil }
        try await task.value
    }
    func connectHevy(key: String) async {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let imported = try await hevyWorkouts(key: value)
            try Vault.set(value, "hevyKey")
            sessions.removeAll { $0.source == "Hevy" }; sessions += imported
            connections["hevy"] = true; message = "Hevy conectado."
            connectionNotice = ConnectionNotice(title: "Hevy conectado", message: "Se han leído \(imported.count) entrenamientos de los últimos 30 días.")
        } catch { message = error.localizedDescription; connectionNotice = ConnectionNotice(title: "No se pudo conectar Hevy", message: message) }
    }
    func refreshHevy() async {
        let key = Vault.get("hevyKey"); guard !key.isEmpty else { return }
        do {
            let imported = try await hevyWorkouts(key: key)
            sessions.removeAll { $0.source == "Hevy" }; sessions += imported; connections["hevy"] = true
        } catch { message = "Hevy: \(error.localizedDescription)" }
    }
    func hevyWorkouts(key: String) async throws -> [Session] {
        guard !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var result: [Session] = []
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? { guard let value = value as? String else { return nil }; return fractional.date(from: value) ?? standard.date(from: value) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        for page in 1...100 {
            var r = URLRequest(url: URL(string: "https://api.hevyapp.com/v1/workouts?page=\(page)&pageSize=10")!)
            r.setValue(key, forHTTPHeaderField: "api-key"); r.timeoutInterval = 25
            let (data, response) = try await URLSession.shared.data(for: r)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "Hevy", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo consultar Hevy. Revisa tu clave Pro y vuelve a intentarlo."])
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any], let workouts = payload["workouts"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            for w in workouts {
                guard let id = w["id"] as? String, let start = date(w["start_time"]), let end = date(w["end_time"]), start >= cutoff else { continue }
                let exercises = (w["exercises"] as? [[String: Any]] ?? []).map { exercise -> String in
                    let sets = (exercise["sets"] as? [[String: Any]] ?? []).map { s in "\(s["reps"] as? Int ?? 0) reps · \(s["weight_kg"] as? Double ?? 0) kg" }.joined(separator: "\n")
                    return (exercise["title"] as? String ?? "Ejercicio") + "\n" + sets
                }.joined(separator: "\n\n")
                result.append(Session(id: "hevy-" + id, title: w["title"] as? String ?? "Fuerza", sport: "Fuerza", date: start, minutes: max(0, end.timeIntervalSince(start) / 60), source: "Hevy", detail: exercises))
            }
            if workouts.isEmpty || page >= (payload["page_count"] as? Int ?? page) { break }
        }
        return result
    }
    func disconnect(_ provider: String) async {
        do {
            if provider == "hevy" { try Vault.set("", "hevyKey") }
            _ = try await request("api/connections/\(provider)", method: "DELETE")
            sessions.removeAll { $0.source.lowercased() == provider }
            if provider == "fatsecret" { clearNutritionCache() }
            connections[provider] = false; message = "Cuenta desconectada."
            connectionNotice = ConnectionNotice(title: "Cuenta desconectada", message: message)
        } catch { message = error.localizedDescription; connectionNotice = ConnectionNotice(title: "No se pudo desconectar", message: message) }
    }
}

// Reuses the private website's own login, OAuth endpoints, and first-party cookies.
// JavaScript can read API data only while the main frame is on this exact origin.
@MainActor final class WebsiteConnectionStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let origin = URL(string: "https://athlete-lab-marc.grittylion20.chatgpt.site")!
    let webView: WKWebView
    @Published var status = ""
    @Published var working = false
    @Published var snapshot: WebsiteSnapshot?
    var onSnapshot: ((WebsiteSnapshot) -> Void)?
    private var pendingProvider: String?
    private var attemptedAuthorization = false
    private var importing = false
    private var refreshing = false
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }
    private var isTrustedPage: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "https" && url.host == Self.origin.host && url.port == nil
    }
    func connect(_ provider: String) {
        guard ["strava", "fatsecret", "hevy"].contains(provider) else { return }
        pendingProvider = provider; attemptedAuthorization = false; importing = false
        status = "Accede a tu web privada si se solicita. Después se abrirá la autorización del servicio."
        working = true
        webView.load(URLRequest(url: Self.origin))
    }
    func finishInteraction() { pendingProvider = nil; working = false }
    func startIfPreviouslyLinked() {
        guard UserDefaults.standard.bool(forKey: "websiteLinked"), webView.url == nil else { return }
        webView.load(URLRequest(url: Self.origin))
    }
    private func api(_ path: String, method: String = "GET") async throws -> String {
        guard isTrustedPage else { throw URLError(.userAuthenticationRequired) }
        // Arguments are passed separately, never interpolated into JavaScript.
        let result = try await webView.callAsyncJavaScript("""
            if (location.origin !== trustedOrigin) throw new Error('La página actual no pertenece a Athlete Lab.');
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), method === 'POST' ? 90000 : 25000);
            try {
                const response = await fetch(path, {method, credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: controller.signal});
                const type = response.headers.get('content-type') || '';
                if (!type.includes('application/json')) throw new Error('Accede primero a tu web de Athlete Lab.');
                const data = await response.json();
                if (!response.ok) throw new Error(data.error || 'No se ha podido consultar el servicio.');
                return JSON.stringify(data);
            } finally { clearTimeout(timer); }
            """, arguments: ["path": path, "method": method, "trustedOrigin": Self.origin.absoluteString], in: nil, contentWorld: .page)
        guard let text = result as? String else { throw URLError(.cannotParseResponse) }
        return text
    }
    private func loadSnapshot() async throws -> WebsiteSnapshot {
        let raw = try await api("/api/data")
        let value = try JSONDecoder().decode(WebsiteSnapshot.self, from: Data(raw.utf8))
        snapshot = value
        if value.providers.values.contains(where: { $0.connected }) { UserDefaults.standard.set(true, forKey: "websiteLinked") }
        onSnapshot?(value)
        return value
    }
    func refresh() async {
        guard !refreshing, !importing else { return }
        guard isTrustedPage else { startIfPreviouslyLinked(); return }
        refreshing = true; defer { refreshing = false }
        do { _ = try await loadSnapshot() }
        catch { if pendingProvider != nil { status = "No se pudo leer la web. Completa el acceso y pulsa Actualizar. \(error.localizedDescription)" } }
    }
    func retry() async {
        attemptedAuthorization = false
        await processPage()
    }
    private func processPage() async {
        guard isTrustedPage, !importing else { return }
        importing = true; defer { importing = false; working = false }
        do {
            var data = try await loadSnapshot()
            guard let provider = pendingProvider else { return }
            guard let state = data.providers[provider] else { throw URLError(.cannotParseResponse) }
            if state.connected {
                if provider != "hevy" || state.mode == "api" {
                    status = "Cuenta autorizada. Consultando los registros del servicio…"
                    do {
                        _ = try await api("/api/integrations/\(provider)/sync", method: "POST")
                        data = try await loadSnapshot()
                    } catch {
                        status = "La cuenta está autorizada, pero la actualización falló. Se conservan los registros de la web. \(error.localizedDescription)"
                        pendingProvider = nil
                        return
                    }
                }
                let count = data.records.filter { $0.source == provider && $0.category == (provider == "fatsecret" ? "food" : "workout") }.count
                status = "Cuenta vinculada con tu web. \(count) registros disponibles." + (provider == "hevy" && state.mode == "connector" ? " Hevy utiliza los registros importados a la web mediante su conexión de ChatGPT; no es una conexión directa de la app con Hevy." : "")
                pendingProvider = nil
            } else if provider == "hevy" {
                status = "Hevy aún no está vinculado en tu web. Sin una clave de su API pública, esta app puede leer sus entrenamientos desde Salud o los que hayas importado a la web con la conexión de Hevy en ChatGPT. Iniciar sesión en hevy.com por sí solo no autoriza esta app."
            } else if !state.configured {
                status = "Falta configurar la aplicación de \(provider == "strava" ? "Strava" : "FatSecret") en tu web. No se puede abrir la autorización sin esas credenciales. Si ya la configuraste, comprueba que has entrado con la misma cuenta de la web."
            } else if !attemptedAuthorization {
                attemptedAuthorization = true
                let raw = try await api("/api/integrations/\(provider)/start", method: "POST")
                let payload = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
                guard let rawURL = payload["url"], let url = URL(string: rawURL), url.scheme == "https", url.host == (provider == "strava" ? "www.strava.com" : "authentication.fatsecret.com") else { throw URLError(.badURL) }
                status = "Inicia sesión en el servicio y autoriza a Athlete Lab."
                webView.load(URLRequest(url: url))
            } else {
                status = "La cuenta todavía no está autorizada. Completa el acceso o pulsa Actualizar para reintentarlo."
            }
        } catch { status = "Completa el acceso a tu web y pulsa Actualizar. \(error.localizedDescription)" }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        working = false
        if !isTrustedPage, pendingProvider != nil { status = "Completa el acceso en \(webView.url?.host ?? "el servicio"). Al autorizar, regresarás a Athlete Lab." }
        Task { await processPage() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { working = false; status = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["https", "about"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else { decisionHandler(.cancel); status = "Completa la autorización en la página web del servicio para regresar a Athlete Lab." }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep provider popups in the same persistent web session.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}


extension Model {
    func applyWebsite(_ snapshot: WebsiteSnapshot) {
        sessions.removeAll { $0.id.hasPrefix("web-") }
        sessions += snapshot.sessions
        for provider in ["hevy", "strava", "fatsecret"] {
            connections["web-" + provider] = snapshot.providers[provider]?.connected == true
        }
        if snapshot.providers["fatsecret"]?.connected == true {
            meals = snapshot.meals(on: selectedDay)
            mealsDay = selectedDay
            nutritionSource = "FatSecret · tu web de Athlete Lab"
        } else if nutritionSource == "FatSecret · tu web de Athlete Lab" {
            meals = []; mealsDay = nil; nutritionSource = nil
        }
    }
}
