import SwiftUI

@main
struct DisquEZApp: App {
    @State private var session = CompressionSession()
    @State private var purchase = ProfessionalPurchase.live
    @State private var presets = ProfessionalPresets()

    var body: some Scene {
        WindowGroup {
            HomeView(session: session)
                .environment(purchase)
                .environment(presets)
                .task { await purchase.observeTransactions() }
                .preferredColorScheme(.dark)
        }
    }
}
