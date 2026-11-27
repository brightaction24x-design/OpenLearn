//
//  MaterialFile.swift
//  OpenLearn
//
//  Created by Abdullah  on 23/11/2026.
//


import Foundation
import AppKit
import PDFKit
import Compression

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Imported file model
struct MaterialFile: Identifiable, Codable {
    enum Kind: String, Codable {
        case text    // Word, PowerPoint, Excel, plain text: read as text on your Mac
        case image   // sent to the AI as a picture
        case pdf     // sent to the AI as a PDF (text is kept as a backup)
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var storedName: String? = nil   // copy kept on disk (images and PDFs)
    var text: String = ""           // extracted text

    var icon: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        }
    }
}

enum ImportError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case exportFirst(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "\(name): this file type isn't supported. Use PDF, images, Word (.docx), PowerPoint (.pptx), Excel (.xlsx), or text files."
        case .unreadable(let name):
            return "\(name): couldn't read any content. For scanned documents, import them as a PDF or image. Also check that Signing & Capabilities → App Sandbox → File Access → User Selected File is set to Read Only."
        case .exportFirst(let name):
            return "\(name): Apple Pages, Keynote and Numbers files can't be read directly. Open it in that app, choose File → Export To → PDF, then add the exported PDF here."
        }
    }
}

// MARK: - Importer
enum FileImporter {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    private static let plainExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv"]
    private static let maxTextLength = 150_000

    static var filesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenLearn/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func importFile(at url: URL) throws -> MaterialFile {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        
        if ["pages", "key", "numbers"].contains(ext) {
            throw ImportError.exportFirst(name)
        }

        // Pictures: shrink and save as JPEG so the AI can look at them
        if imageExtensions.contains(ext) {
            guard let image = NSImage(contentsOf: url), let jpeg = jpegData(from: image) else {
                throw ImportError.unreadable(name)
            }
            let stored = UUID().uuidString + ".jpg"
            try jpeg.write(to: filesDirectory.appendingPathComponent(stored), options: .atomic)
            return MaterialFile(name: name, kind: .image, storedName: stored)
        }

        // PDFs: keep the file (the AI reads it directly) plus the text as a backup
        if ext == "pdf" {
            guard let document = PDFDocument(url: url),
                  let data = try? Data(contentsOf: url) else {
                throw ImportError.unreadable(name)
            }
            let text = String((document.string ?? "").prefix(maxTextLength))
            let stored = UUID().uuidString + ".pdf"
            try data.write(to: filesDirectory.appendingPathComponent(stored), options: .atomic)
            return MaterialFile(name: name, kind: .pdf, storedName: stored, text: text)
        }

        // Everything else is read as text
        var text = ""
        if plainExtensions.contains(ext) {
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        } else if ["docx", "pptx", "xlsx"].contains(ext) {
            text = officeText(at: url, ext: ext)
        } else if ["rtf", "doc"].contains(ext) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
        } else {
            throw ImportError.unsupported(name)
        }

        guard !text.trimmed.isEmpty else { throw ImportError.unreadable(name) }
        return MaterialFile(name: name, kind: .text, text: String(text.prefix(maxTextLength)))
    }

    static func fileData(for file: MaterialFile) -> Data? {
        guard let stored = file.storedName else { return nil }
        return try? Data(contentsOf: filesDirectory.appendingPathComponent(stored))
    }

    static func deleteStoredFile(for file: MaterialFile) {
        guard let stored = file.storedName else { return }
        try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(stored))
    }

    // MARK: Pictures
    private static func jpegData(from image: NSImage, maxDimension: CGFloat = 2000) -> Data? {
        var width = image.size.width
        var height = image.size.height
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            width = CGFloat(rep.pixelsWide)
            height = CGFloat(rep.pixelsHigh)
        }
        guard width > 0, height > 0 else { return nil }

        let scale = min(1, maxDimension / max(width, height))
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        let target = NSImage(size: size)
        target.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        target.unlockFocus()

        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: Word / PowerPoint / Excel
    private static func officeText(at url: URL, ext: String) -> String {
        guard let zip = ZipArchive(url: url) else { return "" }

        switch ext {
        case "docx":
            guard let xml = zip.string(named: "word/document.xml") else { return "" }
            return OfficeXML.text(from: xml, pattern: OfficeXML.wordAndSlides)

        case "pptx":
            let slideNames = zip.names(prefix: "ppt/slides/slide", suffix: ".xml")
                .sorted { slideNumber($0) < slideNumber($1) }
            var parts: [String] = []
            for (i, name) in slideNames.enumerated() {
                if let xml = zip.string(named: name) {
                    let text = OfficeXML.text(from: xml, pattern: OfficeXML.wordAndSlides)
                    if !text.isEmpty { parts.append("Slide \(i + 1):\n\(text)") }
                }
            }
            return parts.joined(separator: "\n\n")

        case "xlsx":
            guard let xml = zip.string(named: "xl/sharedStrings.xml") else { return "" }
            return OfficeXML.text(from: xml, pattern: OfficeXML.sharedStrings)

        default:
            return ""
        }
    }

    private static func slideNumber(_ name: String) -> Int {
        Int(name.filter { $0.isNumber }) ?? 0
    }
}

// MARK: - Pulls readable text out of Office XML
enum OfficeXML {
    // <a:t> (PowerPoint) and <w:t> (Word) hold text; paragraph ends become new lines
    static let wordAndSlides = try! NSRegularExpression(
        pattern: "<(?:a|w):t(?:\\s[^>]*)?>([^<]*)</(?:a|w):t>|</(?:a|w):p>|<w:tab/>|<w:br/>"
    )
    // Excel keeps its text in a shared strings table
    static let sharedStrings = try! NSRegularExpression(
        pattern: "<t(?:\\s[^>]*)?>([^<]*)</t>|</si>"
    )

    static func text(from xml: String, pattern: NSRegularExpression) -> String {
        let ns = xml as NSString
        var out = ""
        for match in pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let group = match.range(at: 1)
            if group.location != NSNotFound {
                out += decode(ns.substring(with: group))
            } else {
                out += ns.substring(with: match.range).hasPrefix("<w:tab") ? "\t" : "\n"
            }
        }
        return out
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Minimal ZIP reader (.docx, .pptx and .xlsx files are ZIP files)
struct ZipArchive {
    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [Entry] = []

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 22 else { return nil }
        data = d

        // Find the "end of central directory" record at the end of the file
        var eocd = -1
        var i = d.count - 22
        let lowest = max(0, d.count - 22 - 65535)
        while i >= lowest {
            if d[i] == 0x50, d[i + 1] == 0x4b, d[i + 2] == 0x05, d[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        var found: [Entry] = []

        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(offset) == 0x02014b50 else { break }
            let method = u16(offset + 10)
            let compressedSize = u32(offset + 20)
            let uncompressedSize = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let localOffset = u32(offset + 42)

            guard offset + 46 + nameLength <= data.count else { break }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            found.append(Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }

    func names(prefix: String, suffix: String) -> [String] {
        entries.map { $0.name }.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
    }

    func string(named name: String) -> String? {
        guard let entry = entries.first(where: { $0.name == name }),
              let bytes = read(entry) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private func read(_ entry: Entry) -> Data? {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, u32(base) == 0x04034b50 else { return nil }

        let start = base + 30 + u16(base + 26) + u16(base + 28)
        let end = start + entry.compressedSize
        guard end <= data.count else { return nil }

        let chunk = data.subdata(in: start..<end)
        if entry.method == 0 { return chunk }          // stored, no compression
        guard entry.method == 8 else { return nil }    // 8 = deflate

        var output = Data(count: max(entry.uncompressedSize, 1))
        let written: Int = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            chunk.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, dst.count, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output.prefix(written))
    }

    private func u16(_ o: Int) -> Int {
        Int(data[o]) | (Int(data[o + 1]) << 8)
    }

    private func u32(_ o: Int) -> Int {
        Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
    }
}
