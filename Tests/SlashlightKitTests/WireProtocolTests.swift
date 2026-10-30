import Foundation
import Testing
@testable import SlashlightKit

@Suite("Wire protocol")
struct WireProtocolTests {
    @Test func iconRoundTrip() {
        guard case .symbol("star") = Wire.decodeIcon(Wire.encode(.symbol("star"))) else { Issue.record("symbol"); return }
        guard case .file("/Applications/Safari.app") = Wire.decodeIcon(Wire.encode(.file("/Applications/Safari.app"))) else { Issue.record("file"); return }
        guard case .text("😀") = Wire.decodeIcon(Wire.encode(.text("😀"))) else { Issue.record("text"); return }
    }

    @Test func unknownIconsFallBack() {
        guard case .symbol("puzzlepiece.extension") = Wire.decodeIcon(nil) else { Issue.record("nil"); return }
        guard case .symbol("bolt") = Wire.decodeIcon("bolt") else { Issue.record("bare name"); return }
    }

    @Test(arguments: [("list", 0), ("grid:3", 3), ("grid:8", 8)])
    func layoutRoundTrip(name: String, columns: Int) {
        let layout = Wire.decodeLayout(name)
        #expect(Wire.encode(layout) == name)
        if columns > 0 {
            guard case .grid(let c) = layout else { Issue.record("expected grid"); return }
            #expect(c == columns)
        }
    }

    @Test func badLayoutIsList() {
        guard case .list = Wire.decodeLayout(nil) else { Issue.record("nil"); return }
        guard case .grid(3) = Wire.decodeLayout("grid") else { Issue.record("grid without columns"); return }
    }

    @Test func triggers() {
        guard case .defaultSearch = Wire.decodeTrigger("default") else { Issue.record("default"); return }
        guard case .commands = Wire.decodeTrigger("commands") else { Issue.record("commands"); return }
        guard case .prefix(">") = Wire.decodeTrigger("prefix:>") else { Issue.record("prefix"); return }
        guard case .command("hello") = Wire.decodeTrigger("command:hello") else { Issue.record("command"); return }
        #expect(Wire.decodeTrigger("nonsense") == nil)
    }

    @Test func requestEncodesOnlyPresentFields() throws {
        let data = try JSONEncoder().encode(Wire.Request(type: "search", id: 7, query: "hi", mode: "default"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "search")
        #expect(json["id"] as? Int == 7)
        #expect(json["view"] == nil)
    }

    @Test func decodesV2DetailMessage() throws {
        let line = #"{"type":"detail","view":"v1","text":"done","append":true,"running":false}"#
        let msg = try JSONDecoder().decode(Wire.Message.self, from: Data(line.utf8))
        #expect(msg.type == "detail")
        #expect(msg.view == "v1")
        #expect(msg.text == "done")
        #expect(msg.append == true)
        #expect(msg.running == false)
    }

    @Test func decodesPushOutcome() throws {
        let line = #"{"type":"outcome","id":3,"outcome":{"type":"push","view":{"id":"v2","title":"Waves","layout":"grid:3","filters":["All","Big"]}}}"#
        let msg = try JSONDecoder().decode(Wire.Message.self, from: Data(line.utf8))
        let view = try #require(msg.outcome?.view)
        #expect(view.title == "Waves")
        #expect(view.filters == ["All", "Big"])
    }
}
