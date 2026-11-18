import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

struct Root: View {
    @EnvironmentObject var m: Model
    @Environment(\.scenePhase) var phase
    @ViewState var settings = false
    @ViewState private var lastKnownToday = Calendar.current.startOfDay(for: Date.now)
    @EnvironmentObject var appearance: AppearanceStore
    var body: some View {
        TabView {
            NavigationStack { Today().navigationTitle("Hoy").toolbar { Button { settings = true } label: { Image(systemName: "person.crop.circle") } } }.tabItem { Label("Hoy", systemImage: "house") }
            NavigationStack { PlanView().navigationTitle("Mi plan") }.tabItem { Label("Plan", systemImage: "calendar") }
            NavigationStack { History().navigationTitle("Actividad") }.tabItem { Label("Actividad", systemImage: "heart") }
            NavigationStack { Nutrition(openSettings: { settings = true }).navigationTitle("Nutrición") }.tabItem { Label("Nutrición", systemImage: "fork.knife") }
            NavigationStack { Recovery().navigationTitle("Recuperación") }.tabItem { Label("Recuperación", systemImage: "heart.text.square.fill") }
        }.toolbarBackground(LabPalette.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .tint(LabPalette.accent)
        .background(WindowAppearanceBridge(isDark: appearance.isDark).frame(width: 0, height: 0).allowsHitTesting(false))
        .preferredColorScheme(appearance.scheme)
        .sheet(isPresented: $settings) {
            NavigationStack {
                Connections().navigationTitle("Ajustes").toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { settings = false } label: { Image(systemName: "checkmark").font(.body.weight(.semibold)).frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Cerrar ajustes").buttonStyle(.borderless)
                    }
                }
            }.tint(LabPalette.accent).preferredColorScheme(appearance.scheme)
        }
        .task { while !Task.isCancelled { updateDayIfNeeded(); if phase == .active { await m.sync() }; do { try await Task.sleep(for: .seconds(120)) } catch { return } } }
        .onChange(of: m.selectedDay) { _, _ in m.showCachedNutrition(); m.nightSleepHours = nil; m.nightDate = nil; Task { await m.refreshNutrition(); await m.readNight(for: m.selectedDay) } }
        .onChange(of: phase) { _, value in if value == .active { updateDayIfNeeded(); Task { await m.sync() } } }
    }
    private func updateDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date.now)
        guard today != lastKnownToday else { return }
        if Calendar.current.isDate(m.selectedDay, inSameDayAs: lastKnownToday) { m.selectedDay = today }
        lastKnownToday = today
    }
}


@MainActor final class AppearanceStore: ObservableObject {
    @Published var isDark: Bool {
        didSet { defaults.set(isDark ? "dark" : "light", forKey: "appearance") }
    }
    private let defaults: UserDefaults
    var scheme: ColorScheme { isDark ? .dark : .light }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "appearance")
        if saved == "dark" { isDark = true }
        else if saved == "light" { isDark = false }
        else { isDark = false }
    }
}

struct WindowAppearanceBridge: UIViewRepresentable {
    let isDark: Bool
    func makeUIView(context: Context) -> AppearanceAnchor { AppearanceAnchor() }
    func updateUIView(_ view: AppearanceAnchor, context: Context) {
        view.style = isDark ? .dark : .light
        view.applyStyle()
    }
}
final class AppearanceAnchor: UIView {
    var style: UIUserInterfaceStyle = .light
    override func didMoveToWindow() { super.didMoveToWindow(); applyStyle() }
    func applyStyle() {
        guard window?.overrideUserInterfaceStyle != style else { return }
        window?.overrideUserInterfaceStyle = style
    }
}
