import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Slashlight

@Suite("Clipboard history")
@MainActor
struct ClipboardTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("slashlight-test-\(UUID().uuidString)")) }

    @Test func keepsFormattingOnCopyBack() throws {
        // What a browser puts on the clipboard when copying from Google Docs: plain, HTML and the app's own type.
        let pb = board()
        let item = NSPasteboardItem()
        item.setString("Hello bold", forType: .string)
        item.setString("<b>Hello</b> bold", forType: .html)
        item.setData(Data([1, 2, 3]), forType: .init("org.chromium.web-custom-data"))
        pb.clearContents()
        pb.writeObjects([item])

        let entry = try #require(ClipboardCapture.capture(pb, source: "Chrome"))
        #expect(entry.kind == .text)
        #expect(entry.text == "Hello bold")

        let out = board()
        ClipboardCapture.restore(entry, to: out)
        #expect(out.string(forType: .html) == "<b>Hello</b> bold")
        #expect(out.data(forType: .init("org.chromium.web-custom-data")) == Data([1, 2, 3]))
        #expect(out.string(forType: .string) == "Hello bold")
    }

    @Test func readsRichTextWithoutPlainText() throws {
        let rtf = try NSAttributedString(string: "Quarterly plan").data(from: NSRange(location: 0, length: 14),
                                                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pb = board()
        pb.clearContents()
        pb.setData(rtf, forType: .rtf)
        let entry = try #require(ClipboardCapture.capture(pb, source: nil))
        #expect(entry.kind == .text)
        #expect(entry.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Quarterly plan")
    }

    @Test func recognizesImages() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let pb = board()
        pb.clearContents()
        pb.setData(png, forType: .png)
        let entry = try #require(ClipboardCapture.capture(pb, source: nil))
        #expect(entry.kind == .image)
        #expect(entry.pixels == [40, 20])
        #expect(entry.imageData == png)
    }

    @Test func recognizesFiles() throws {
        let pb = board()
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/etc/hosts") as NSURL])
        let entry = try #require(ClipboardCapture.capture(pb, source: "Finder"))
        #expect(entry.kind == .files)
        #expect(entry.fileURLs.map(\.path) == ["/etc/hosts"])
    }

    @Test func skipsPasswordManagerCopies() {
        let pb = board()
        pb.clearContents()
        pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString("hunter2", forType: .string)
        #expect(ClipboardCapture.capture(pb, source: "1Password")?.id == nil)
    }

    @Test func vaultRoundTripsAndNeedsTheKey() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let entry = ClipEntry(date: Date(), source: "Notes", kind: .text, text: "secret note",
                              items: [["public.utf8-plain-text": Data("secret note".utf8)]], fingerprint: "text:x")
        let vault = ClipboardVault(directory: dir, key: key)
        vault.save(entry)
        vault.flush()

        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("secret note".utf8)) == nil, "history is written in plain text")

        #expect(ClipboardVault(directory: dir, key: key).loadAll().map(\.text) == ["secret note"])
        #expect(ClipboardVault(directory: dir, key: SymmetricKey(size: .bits256)).loadAll().isEmpty)

        vault.deleteAll()
        vault.flush()
        #expect(ClipboardVault(directory: dir, key: key).loadAll().isEmpty)
    }
}
