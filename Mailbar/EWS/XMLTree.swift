import Foundation

/// A small element tree built with Foundation's `XMLParser`, so EWS responses can be read by
/// element name without a dependency.
///
/// Names are LOCAL names: `t:Message` and `m:Message` are both `Message`. EWS never reuses a local
/// name across its namespaces in a way that matters to this app, and matching prefixes would
/// break the day a server picks different ones.
final class XMLTreeNode {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [XMLTreeNode] = []
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// The first direct child with this name.
    func child(_ name: String) -> XMLTreeNode? {
        children.first { $0.name == name }
    }

    /// The first descendant with this name, depth first.
    func first(_ name: String) -> XMLTreeNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    /// Every descendant with this name, in document order.
    func all(_ name: String) -> [XMLTreeNode] {
        var found: [XMLTreeNode] = []
        for child in children {
            if child.name == name { found.append(child) }
            found.append(contentsOf: child.all(name))
        }
        return found
    }

    /// Follows direct children by name: `node.path("From", "Mailbox", "Name")`.
    func path(_ names: String...) -> XMLTreeNode? {
        var node: XMLTreeNode? = self
        for name in names { node = node?.child(name) }
        return node
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum XMLTree {
    struct ParseError: Error {
        let message: String
    }

    static func parse(_ data: Data) throws -> XMLTreeNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        // Never fetch a DTD or an entity from the network. EWS sends neither, and a response that
        // did should not be able to make this app reach anywhere.
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription ?? "unreadable"
            throw ParseError(message: "The server's reply was not valid XML (\(reason)).")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTreeNode?
        private var stack: [XMLTreeNode] = []

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let node = XMLTreeNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
