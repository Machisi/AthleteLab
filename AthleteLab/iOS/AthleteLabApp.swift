import SwiftUI
import Charts
import HealthKit
import AuthenticationServices
import Security

@main struct AthleteLabApp: App {
    @StateObject private var appearance = AppearanceStore()
    @StateObject private var model = Model()
    @StateObject private var athlete = AthleteProfileStore()
    var body: some Scene { WindowGroup { Root().environmentObject(model).environmentObject(athlete).environmentObject(appearance) } }
}
