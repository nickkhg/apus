// A small XML reader for Wayland protocol files: elements, attributes and
// text. It skips the XML declaration, comments and processing instructions.

import Foundation

final class Node {
    let name: String
    let attributes: [String: String]
    var children: [Node] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(attribute: String) -> String? { attributes[attribute] }

    func elements(_ name: String) -> [Node] { children.filter { $0.name == name } }
    func element(_ name: String) -> Node? { children.first { $0.name == name } }
}

struct XMLError: Error, CustomStringConvertible {
    let description: String
}

func parseXML(_ source: String) throws -> Node {
    var scanner = ByteScanner(Array(source.utf8))
    let root = Node(name: "#document", attributes: [:])
    var stack = [root]

    while !scanner.atEnd {
        if scanner.skip("<!--") {
            try scanner.skip(past: "-->")
        } else if scanner.skip("<?") {
            try scanner.skip(past: "?>")
        } else if scanner.skip("<![CDATA[") {
            stack.last!.text += try scanner.read(until: "]]>")
        } else if scanner.skip("<!") {
            try scanner.skip(past: ">")
        } else if scanner.skip("</") {
            let name = scanner.readName()
            scanner.skipSpace()
            guard scanner.skip(">"), stack.count > 1, stack.last!.name == name else {
                throw XMLError(description: "unexpected </\(name)>")
            }
            stack.removeLast()
        } else if scanner.skip("<") {
            let name = scanner.readName()
            var attributes: [String: String] = [:]
            while true {
                scanner.skipSpace()
                if scanner.skip("/>") {
                    stack.last!.children.append(Node(name: name, attributes: attributes))
                    break
                }
                if scanner.skip(">") {
                    let element = Node(name: name, attributes: attributes)
                    stack.last!.children.append(element)
                    stack.append(element)
                    break
                }
                let key = scanner.readName()
                scanner.skipSpace()
                guard !key.isEmpty, scanner.skip("=") else { throw XMLError(description: "bad attribute in <\(name)>") }
                scanner.skipSpace()
                guard let quote = scanner.next(), quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
                    throw XMLError(description: "unquoted attribute \(key) in <\(name)>")
                }
                attributes[key] = decodeEntities(try scanner.read(until: String(UnicodeScalar(quote))))
            }
        } else {
            stack.last!.text += decodeEntities(scanner.read(upTo: UInt8(ascii: "<")))
        }
    }
    guard stack.count == 1 else { throw XMLError(description: "<\(stack.last!.name)> is not closed") }
    return root
}

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    return text
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

private struct ByteScanner {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { position >= bytes.count }

    mutating func next() -> UInt8? {
        guard !atEnd else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    func hasPrefix(_ string: String) -> Bool {
        let prefix = Array(string.utf8)
        return position + prefix.count <= bytes.count && Array(bytes[position..<position + prefix.count]) == prefix
    }

    mutating func skip(_ string: String) -> Bool {
        guard hasPrefix(string) else { return false }
        position += string.utf8.count
        return true
    }

    mutating func skipSpace() {
        while let byte = bytes[safe: position], byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            position += 1
        }
    }

    mutating func readName() -> String {
        let start = position
        while let byte = bytes[safe: position],
              byte != 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D,
              byte != UInt8(ascii: "="), byte != UInt8(ascii: ">"), byte != UInt8(ascii: "/") {
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// Reads up to (not including) `terminator`, and skips the terminator.
    mutating func read(until terminator: String) throws -> String {
        let start = position
        while !atEnd, !hasPrefix(terminator) { position += 1 }
        guard !atEnd else { throw XMLError(description: "missing \(terminator)") }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        position += terminator.utf8.count
        return text
    }

    mutating func skip(past terminator: String) throws {
        _ = try read(until: terminator)
    }

    mutating func read(upTo byte: UInt8) -> String {
        let start = position
        while let next = bytes[safe: position], next != byte { position += 1 }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
