import Foundation
import Testing
@testable import DmainAdminCore

/// Lines as `dmain admin house --json` writes them, names changed.
let linkLine = #"{"link":{"state":"up","why":null,"newest_ms":1794555614423}}"#
let attentionLine = #"""
{"attention":{"services":[],"console":{"up":true,"busy":false,"text":"hub's console: answering"},
"config":[{"name":"switches","text":"07:40 would change   21 dimmers, 2 would change.","mark":"differs"}],
"sections":[{"screen":"power_on","label":"Power-on","summary":"54 lights, 0 differ","columns":["Name","Now","Wanted"],"count":0,"rows":[]},
{"screen":"heard","label":"Last heard","summary":"96 devices, 2 with a bad link","columns":["Name","Link","Last heard","Room"],"count":2,
"rows":[{"cells":["motion2","not reported","not in the log","Bed 2"],"mark":"differs","dev":"m2"},{"cells":["power1","disconnected","13 h ago","Bed 2"],"mark":"broken","dev":"p1"}]}]}}
"""#
let tableLine = #"""
{"table":{"screen":"battery","label":"Battery","summary":"2 on battery, 1 at 20% or below","columns":["Name","Battery","Room"],"count":1,
"rows":[{"cells":["motion2","12%","Bed 2"],"mark":"differs","dev":"m2"},{"cells":["Dimmer","90%",""],"mark":"none","dev":"d"}]}}
"""#
let logLine = #"{"log":{"events":[{"at":"07:29:10","src":"hue","text":"hue  motion2: motion","mark":"none","dev":"m2"},{"at":"07:29:00","src":"hue","text":"hue  source up","mark":"none","dev":null}]}}"#

@Test func decodesTheLinkLine() throws {
    let line = try StreamLine.decode(Data(linkLine.utf8))
    #expect(line == .link(LinkStatus(state: .up, why: nil, newestMs: 1_794_555_614_423)))
}

@Test func decodesAttentionAndCountsWhatIsMarked() throws {
    guard case let .attention(a) = try StreamLine.decode(Data(attentionLine.utf8)) else {
        Issue.record("expected attention"); return
    }
    #expect(a.count == 3)
    #expect(a.section("heard")?.rows.last?.mark == .broken)
    #expect(a.config?.first?.name == "switches")
    #expect(a.console.up == true)
}

@MainActor @Test func theInspectorGathersOneDeviceFromEveryTable() throws {
    let house = House()
    for line in [tableLine, logLine] {
        house.apply(.line(try #require(try StreamLine.decode(Data(line.utf8)))))
    }
    // A heard table with the same device, as Attention's marked rows would be.
    guard case let .attention(a) = try StreamLine.decode(Data(attentionLine.utf8)) else { Issue.record("attention"); return }
    house.apply(.line(.table(try #require(a.section("heard")))))
    let found = house.device("m2")
    #expect(found.map(\.0.screen) == ["battery", "heard"])
    #expect(found.first?.1.cells[1] == "12%")
    #expect(house.log.filter { $0.dev == "m2" }.count == 1)
    #expect(house.device("nobody").isEmpty)
}

@Test func ignoresAKindOfLineItDoesNotKnow() throws {
    #expect(try StreamLine.decode(Data(#"{"forecast":{}}"#.utf8)) == nil)
}

@MainActor @Test func theLinkStateRecordsWhenItChangedAndNothingIsCleared() throws {
    let house = House()
    let t0 = Date(timeIntervalSince1970: 0), t1 = Date(timeIntervalSince1970: 60)
    let link = try #require(try StreamLine.decode(Data(linkLine.utf8)))
    let attention = try #require(try StreamLine.decode(Data(attentionLine.utf8)))
    house.apply(.line(link), at: t0)
    house.apply(.line(attention), at: t0)
    #expect(!house.isStale)
    house.apply(.line(.link(LinkStatus(state: .up, newestMs: 5))), at: t1)
    #expect(house.since == t0)
    house.apply(.ended("Connection closed by remote host"), at: t1)
    #expect(house.isStale)
    #expect(house.since == t1)
    #expect(house.attention?.count == 3)
}

/// The real process path, with a stand-in for dmain that writes a line and then
/// waits for its stdin to close, as dmain does.
@Test func stoppingClosesStdinAndTheStreamEnds() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "dmain")
    try """
    #!/bin/sh
    echo '\(linkLine)'
    cat > /dev/null
    echo 'stdin closed' >&2
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let stream = try RunningStream(DmainCommand(executable: script, checkout: dir, host: "house"))
    var got: [StreamEvent] = []
    for await event in stream.events {
        got.append(event)
        if got.count == 1 { stream.stop() }
    }
    #expect(got.count == 2)
    #expect(got.last == .ended("stdin closed"))
}

@Test func decodesTheServicesConfigAndRequestLines() throws {
    #expect(try StreamLine.decode(Data(#"{"services":null}"#.utf8)) == .services(nil))
    let s = try StreamLine.decode(Data(#"{"services":[{"unit":"hub","state":"active, running","enabled":"enabled","since":"11-12 18:16","restarts":0,"newer_binary":true,"mark":"differs","cost":"Zigbee stops for about 25 s"}]}"#.utf8))
    guard case let .services(list?) = s else { Issue.record("services"); return }
    #expect(list.first?.newerBinary == true)
    let c = try StreamLine.decode(Data(#"{"config":{"checkout":"/x","targets":[{"name":"switches","to":"the Bridge","files":"switches.json","paths":["/x/switches.json"],"status":"08:01 would change","mark":"differs","what":"last dry run","hash":"b35f28688e1a8641","refusal":null,"lines":["21 dimmers, 2 would change."]}]}}"#.utf8))
    guard case let .config(cfg) = c else { Issue.record("config"); return }
    #expect(cfg.targets?.first?.refusal == nil)
    #expect(try StreamLine.decode(Data(#"{"line":"panel joined"}"#.utf8)) == .output("panel joined"))
    #expect(try StreamLine.decode(Data(#"{"phase":"read back"}"#.utf8)) == .phase("read back"))
    #expect(try StreamLine.decode(Data(#"{"done":{"ok":false,"why":"the files have changed"}}"#.utf8)) == .done(ok: false, why: "the files have changed"))
}

@MainActor @Test func aRequestThatEndsWithoutSayingHowFailed() {
    let r = Request(words: ["restart", "hub"], events: [.line(.phase("check")), .line(.output("queued")), .ended("Connection closed")])
    #expect(r.outcome?.ok == false)
    #expect(r.outcome?.why == "Connection closed")
    #expect(r.lines == ["queued"])
    let good = Request(words: ["hub", "list"], events: [.line(.done(ok: true, why: nil)), .ended("dmain exited with status 0")])
    #expect(good.outcome?.ok == true)
}

@Test func decodesAHistoryWithItsPointsAsPairs() throws {
    let line = #"{"history":{"from":0,"to":86400000,"newest":3600000,"raw":false,"temperature":[{"dev":"k","label":"Kitchen","outside":false,"segments":[[[0,19.5],[600000,20.25]]],"gaps":[{"from":1200000,"to":null,"why":"silent"}]}],"humidity":[],"motion":[{"dev":"k","label":"Kitchen","outdoor":false,"spans":[{"from":0,"to":60000}]}]}}"#
    guard case let .history(h) = try StreamLine.decode(Data(line.utf8)) else { Issue.record("history"); return }
    #expect(h.temperature[0].segments[0][1] == HistoryPoint(t: 600_000, v: 20.25))
    #expect(h.temperature[0].gaps[0].to == nil)
    #expect(h.motion[0].spans.count == 1)
    #expect(Date.fromMs(600_000).ms == 600_000)
}

/// A stand-in for dmain that says its link closed and why, then exits, as a
/// stream does when the server's agent goes.
@Test func aDeviceTheFileDoesNotListIsOfferedAndNothingWhileItWontRead() throws {
    let line = #"{"rooms":{"list":[{"name":"Hall"}],"devices":["a"]}}"#
    guard case let .rooms(rooms) = try StreamLine.decode(Data(line.utf8)) else { Issue.record("rooms"); return }
    let held = [
        DeviceInfo(dev: "a", name: "Ceiling", room: "Hall", network: "hue-bridge", product: nil, has: ["light"], parked: nil),
        DeviceInfo(dev: "b", name: "Bulb", room: nil, network: "hue-bridge", product: nil, has: ["light"], parked: nil),
    ]
    #expect(rooms.unlisted(held).map(\.dev) == ["b"])
    #expect(RoomsState(list: rooms.list, devices: [], err: "rooms.json didn't read (x)").unlisted(held).isEmpty)
    #expect(RoomsState(list: [], devices: [], err: nil).unlisted(held).isEmpty)
}

@Test func decodesTheBridgeWithWhatItDoesNotReportAsNil() throws {
    let line = #"{"bridge":{"name":"Hue Bridge","model":"BSB003","software":"6.3","channel":"channel_25","channel_status":"set","discovery":"active","counts":{"devices":90,"lights":55,"rooms":19,"zones":8,"scenes":138,"automations":39}}}"#
    guard case let .bridge(b) = try StreamLine.decode(Data(line.utf8)) else { Issue.record("bridge"); return }
    #expect(b.model == "BSB003" && b.update == nil && b.counts.scenes == 138)
    #expect(b.searching)
}

@Test func decodesHubsNetworkAndWhyThereIsNone() throws {
    let line = #"{"zigbee":{"network":{"v":1,"src":"hub","t":"2026-11-16T17:12:32.303Z","up":true,"channel":15,"pan":"0xcb2c","children":{"used":1,"size":32},"neighbours":{"used":1},"permit_until_ms":1794849062000,"devices":[{"dev":"a","nwk":"0x96d7","lqi":180,"rssi":-61},{"dev":"b","nwk":"0x0002"}]},"err":null}}"#
    guard case let .zigbee(z) = try StreamLine.decode(Data(line.utf8)) else { Issue.record("zigbee"); return }
    let n = try #require(z.network)
    #expect(n.channel == 15 && n.children.size == 32 && n.neighbours.size == nil)
    #expect(n.devices[0].rssi == -61 && n.devices[1].lqi == nil)
    #expect(n.permitUntil == Date.fromMs(1794849062000))
    let none = #"{"zigbee":{"network":null,"err":"cannot read ../hub/data/network.json (FileNotFound)"}}"#
    guard case let .zigbee(e) = try StreamLine.decode(Data(none.utf8)) else { Issue.record("zigbee"); return }
    #expect(e.network == nil && e.err != nil)
}

@Test func decodesEachRoomsScenes() throws {
    let line = #"{"scenes":[{"room":"Hall","scenes":[]},{"room":"Lounge","scenes":["Read","Relax"]}]}"#
    guard case let .scenes(list) = try StreamLine.decode(Data(line.utf8)) else { Issue.record("scenes"); return }
    #expect(list == [RoomScenes(room: "Hall", scenes: []), RoomScenes(room: "Lounge", scenes: ["Read", "Relax"])])
}

@MainActor @Test func aClosedLinkKeepsItsReasonAndIsTriedAgain() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "dmain")
    try """
    #!/bin/sh
    echo '{"link":{"state":"closed","why":"link to house closed: no reason given","newest_ms":null}}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let house = House()
    house.connect(DmainCommand(executable: script, checkout: dir, host: "house"))
    for _ in 0..<50 where house.ended == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(house.ended == "link to house closed: no reason given")
    #expect(house.reconnectAt != nil)
    house.disconnect()
    #expect(house.reconnectAt == nil)
}

/// After a stream is replaced, the old one ending mustn't mark the new one stopped.
@MainActor @Test func aReplacedStreamEndingIsIgnored() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "dmain")
    try """
    #!/bin/sh
    echo '{"link":{"state":"up","why":null,"newest_ms":1}}'
    cat > /dev/null
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let house = House()
    let command = DmainCommand(executable: script, checkout: dir, host: "house")
    house.connect(command)
    for _ in 0..<50 where house.link == nil { try await Task.sleep(for: .milliseconds(20)) }
    house.connect(command) // the first stream's stdin closes and it ends
    try await Task.sleep(for: .milliseconds(300))
    #expect(house.ended == nil)
    #expect(house.link?.state == .up)
    house.disconnect()
}

@MainActor @Test func theDeviceListSaysWhichNetworkActsOnEachDevice() throws {
    let line = #"{"devices":[{"dev":"00:17:88:01:00:00:00:01","name":"Bulb","room":null,"network":"hub","product":null,"has":["light"]},{"dev":"m2","name":"motion2","room":"Bed 2","network":"hue","product":"SML001","has":["motion","battery"],"parked":"flat battery"}]}"#
    guard case let .devices(list) = try StreamLine.decode(Data(line.utf8)) else {
        Issue.record("expected devices"); return
    }
    let house = House()
    house.apply(.line(.devices(list)))
    #expect(house.devices.count == 2)
    #expect(house.devices[0].onHub)
    #expect(house.devices[1].networkName == "the Bridge")
    #expect(house.devices[1].has.contains("motion"))
    #expect(house.devices[0].parked == nil)
    #expect(house.devices[1].parked == "flat battery")
}
