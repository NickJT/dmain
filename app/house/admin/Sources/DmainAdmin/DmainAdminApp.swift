import DmainAdminCore
import DmainAdminUI
import SwiftUI

@main
struct DmainAdminApp: App {
    @State private var house = House()
    /// The house server, as ssh names it: `house` is an alias for it in
    /// `~/.ssh/config`. Change it with `defaults write local.zig.dmain-admin host <name>`.
    @AppStorage("host") private var host = "house"
    /// `app/house/dmain` in the checkout, whose wanted files dmain dry-runs.
    /// Change it with `defaults write local.zig.dmain-admin checkout <path>`.
    @AppStorage("checkout") private var checkout = "~/dmain/app/house/dmain"

    var body: some Scene {
        Window("Dmain", id: "main") {
            ContentView(house: house, host: host, reconnect: connect)
                .frame(minWidth: 900, minHeight: 560)
                .task { connect() }
        }
        .defaultSize(width: 1100, height: 700)
    }

    private func connect() {
        house.connect(.resolve(checkout: checkout, host: host))
    }
}
