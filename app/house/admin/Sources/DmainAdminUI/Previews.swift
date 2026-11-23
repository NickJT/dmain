import DmainAdminCore
import Foundation
import SwiftUI

/// A house as dmain describes it, made up for previews.
@MainActor func previewHouse(stale: Bool = false) -> House {
    let house = House()
    let link = #"{"link":{"state":"up","why":null,"newest_ms":1794555614423}}"#
    let attention = #"""
    {"attention":{"services":[{"name":"hub","text":"active, running   enabled   since 11-13 09:02   0 restarts   new binary on disk: restart to run it","mark":"differs"}],
    "console":{"up":true,"busy":false,"text":"hub's console: answering"},
    "config":[{"name":"switches","text":"14:21 would change   21 dimmers, 2 would change.","mark":"differs"}],
    "sections":[{"screen":"power_on","label":"Power-on","summary":"55 lights, 1 differ from power-on.json.","columns":["Name","Now","Wanted"],"count":1,"rows":[{"cells":["Lounge - spot 2","last state","powerfail"],"mark":"differs","dev":"l2"}]},
    {"screen":"firmware","label":"Firmware","summary":"96 devices, 0 on other firmware.","columns":["Name","Model","Firmware"],"count":0,"rows":[]},
    {"screen":"battery","label":"Battery","summary":"37 on battery, 1 at 20% or below.","columns":["Name","Battery","Room"],"count":1,"rows":[{"cells":["Hue dimmer switch 7","12%","Hall"],"mark":"differs","dev":"d7"}]},
    {"screen":"heard","label":"Last heard","summary":"96 devices, 1 with a bad link.","columns":["Name","Link","Last heard","Room"],"count":1,"rows":[{"cells":["motion2","disconnected","3 h ago","Bed 2"],"mark":"broken","dev":"m2"}]}]]}}
    """#
    let table = #"""
    {"table":{"screen":"power_on","label":"Power-on","summary":"3 lights, 1 differs from power-on.json.","columns":["Name","Now","Wanted"],"count":1,
    "rows":[{"cells":["Lounge - spot 2","last state","powerfail"],"mark":"differs","dev":"l2"},{"cells":["Hall Ceiling","powerfail","powerfail"],"mark":"none","dev":"h"},
    {"cells":["panel","on, 100%","(on hub: not compared)"],"mark":"none","dev":"p"}]}}
    """#
    let log = #"{"log":{"events":[{"at":"14:31:52","src":"hue","text":"hue  Kitchen: motion","mark":"none","dev":"k"},{"at":"14:02:10","src":"hue","text":"hue  Lounge - spot 2: on","mark":"none","dev":"l2"},{"at":"14:21:03","src":"hue","text":"hue  Hall Ceiling: off","mark":"none","dev":"h"}]}}"#
    for line in [link, attention, table, log] {
        if let l = try? StreamLine.decode(Data(line.utf8)) { house.apply(.line(l)) }
    }
    if stale { house.apply(.ended("Connection to house closed by remote host.")) }
    return house
}

#Preview("Attention") {
    ContentView(house: previewHouse(), host: "house") {}.frame(width: 1100, height: 700)
}

#Preview("Power-on") {
    DeviceTableView(house: previewHouse(), screen: .powerOn).frame(width: 900, height: 500)
}

#Preview("Link gone") {
    ContentView(house: previewHouse(stale: true), host: "house") {}.frame(width: 1100, height: 700)
}
