// Adds one release to a Sparkle appcast, creating the file if needed. Run by .github/workflows/release.yml.
// Usage: swift scripts/appcast.swift <appcast.xml> <tag> <build-number> <download-url> "<sign_update output>" [channel]
// <sign_update output> is the `sparkle:edSignature="…" length="…"` line printed by Sparkle's sign_update.
// Stable items have no channel; beta items get <sparkle:channel>beta</sparkle:channel>. An item with the same tag is replaced.
import Foundation

let args = CommandLine.arguments
guard args.count >= 6 else {
    FileHandle.standardError.write(Data("usage: appcast.swift <appcast.xml> <tag> <build> <url> <signature> [channel]\n".utf8))
    exit(2)
}
let (path, tag, build, url, signature) = (args[1], args[2], args[3], args[4], args[5])
let channel = args.count > 6 ? args[6] : ""
let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

func attribute(_ name: String) -> String {
    guard let range = signature.range(of: #"\#(name)="([^"]*)""#, options: .regularExpression) else {
        FileHandle.standardError.write(Data("missing \(name) in signature: \(signature)\n".utf8))
        exit(1)
    }
    return String(signature[range].dropFirst(name.count + 2).dropLast())
}

let fileURL = URL(fileURLWithPath: path)
let doc: XMLDocument
if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
    doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
} else {
    doc = try XMLDocument(xmlString: """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="\(sparkle)">
      <channel>
        <title>Slashlight</title>
        <link>https://github.com/burinworks/slashlight</link>
        <description>Slashlight updates</description>
        <language>en</language>
      </channel>
    </rss>
    """)
}
guard let rss = doc.rootElement(), let feed = rss.elements(forName: "channel").first else {
    FileHandle.standardError.write(Data("\(path) is not an RSS appcast\n".utf8))
    exit(1)
}

for item in feed.elements(forName: "item") where item.elements(forName: "title").first?.stringValue == "Slashlight \(tag)" {
    item.detach()
}

let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
let release = "https://github.com/burinworks/slashlight/releases/tag/\(tag)"
let date = DateFormatter()
date.locale = Locale(identifier: "en_US_POSIX")
date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

let item = XMLElement(name: "item")
func child(_ name: String, _ value: String) {
    item.addChild(XMLElement(name: name, stringValue: value))
}
child("title", "Slashlight \(tag)")
child("pubDate", date.string(from: Date()))
child("sparkle:version", build)
child("sparkle:shortVersionString", version)
child("sparkle:minimumSystemVersion", "14.0")
child("sparkle:releaseNotesLink", release)
child("sparkle:fullReleaseNotesLink", release)
if !channel.isEmpty { child("sparkle:channel", channel) }
let enclosure = XMLElement(name: "enclosure")
for (key, value) in [("url", url), ("type", "application/octet-stream"),
                     ("sparkle:edSignature", attribute("sparkle:edSignature")), ("length", attribute("length"))] {
    enclosure.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
}
item.addChild(enclosure)

// Newest first, after the channel's own title/link/description.
let firstItem = feed.children?.firstIndex { $0.name == "item" } ?? feed.childCount
feed.insertChild(item, at: firstItem)

try doc.xmlData(options: [.nodePrettyPrint]).write(to: fileURL)
print("Added \(tag) (build \(build)\(channel.isEmpty ? "" : ", \(channel)")) to \(path)")
