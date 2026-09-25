import AppKit
import Foundation

/// A canned people directory for `MAILBAR_MOCK`: invented people at example.com with teams and
/// departments, some with photos (coloured squares drawn here), one departed, one Persian name.
/// DEBUG only in spirit; nothing here reaches the network.
enum MockDirectory {
    static let address = "https://people.example.com/api/users"

    private struct Person {
        let name: String
        let email: String
        let team: String
        let department: String
        let role: String
        var photo = false
        var departed = false
    }

    private static let people: [Person] = [
        Person(name: "Narges Ahmadi", email: "narges@example.com", team: "Design", department: "Product",
               role: "Product Designer", photo: true),
        Person(name: "Ali Tavakoli", email: "ali.tavakoli@example.com", team: "Design", department: "Product",
               role: "Design Lead", photo: true),
        Person(name: "Sara Rahimi", email: "sara.rahimi@example.com", team: "Design", department: "Product",
               role: "UX Researcher"),
        Person(name: "مریم صالحی", email: "maryam.salehi@example.com", team: "Design", department: "Product",
               role: "Illustrator", photo: true),
        Person(name: "Kaveh Shams", email: "kaveh.shams@example.com", team: "Design", department: "Product",
               role: "Designer", departed: true),
        Person(name: "Amir Karimi", email: "amir.karimi@example.com", team: "Platform", department: "Engineering",
               role: "iOS Engineer"),
        Person(name: "Amirhossein Nadiri", email: "amirhossein.nadiri@example.com", team: "Platform",
               department: "Engineering", role: "Backend Engineer", photo: true),
        Person(name: "Leila Moradi", email: "leila.moradi@example.com", team: "Platform", department: "Engineering",
               role: "Engineering Manager", photo: true),
        Person(name: "Mina Jafari", email: "mina.jafari@example.com", team: "Support", department: "Operations",
               role: "Support Lead", photo: true),
        Person(name: "Reza Hosseini", email: "reza.hosseini@example.com", team: "Support", department: "Operations",
               role: "Support Specialist"),
    ]

    /// The same shape a real people list takes: `items`, a work email, a relative photo path,
    /// "default" for none.
    static var json: Data {
        let items: [[String: Any]] = people.map { person in
            var item: [String: Any] = [
                "name": person.name, "workEmail": person.email, "team": person.team,
                "department": person.department, "role": person.role,
                "avatar": "/images/avatars/\(person.photo ? slug(person.email) : "default").png",
            ]
            if person.departed { item["employment"] = "departed" }
            return item
        }
        return (try? JSONSerialization.data(withJSONObject: ["items": items])) ?? Data()
    }

    @Sendable static func fetch(_ url: URL) async throws -> Data {
        try await Task.sleep(nanoseconds: 300_000_000)
        if url.path.hasPrefix("/images/avatars/") {
            return await MainActor.run { photo(seed: url.lastPathComponent) }
        }
        return json
    }

    private static func slug(_ email: String) -> String {
        String(email.prefix { $0 != "@" }).replacingOccurrences(of: ".", with: "-")
    }

    /// A coloured square with a white head and shoulders, the hue taken from the file name.
    @MainActor
    private static func photo(seed: String) -> Data {
        let hue = CGFloat(seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        let size = 96
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 30, y: 46, width: 36, height: 36)).fill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: -30, width: 68, height: 70)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
