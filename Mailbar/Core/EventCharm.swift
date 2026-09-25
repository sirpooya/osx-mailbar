import Foundation

/// OWA's charms: a small icon an event carries next to its title (the user's request,
/// 2026-09-25). Exchange keeps it in one integer extended property, 0x0027 in the property set
/// below, 1 to 33 in OWA's order; no property is "None". Not in the EWS documentation: read from
/// how OWA and Graph store it, and unproven on the user's on-prem server until a real one shows.
enum EventCharm: Int, CaseIterable, Identifiable, Sendable {
    case cat = 1, dog, plane, document, firstAid, trophy, home
    case pill, luggage, cup, group, timer, music, shopping
    case car, star, notes, person, balloon, forkKnife, heart
    case soccer, movie, chart, books, cake, tv, travel
    case package, promotion, ticket, hotel, creditCard

    var id: Int { rawValue }

    static let propertySetID = "11000E07-B51B-40D6-AF21-CAA85EDAB1D0"
    static let propertyID = 0x0027

    /// The `ExtendedFieldURI` element, for reading and writing it.
    static let fieldURI = #"<t:ExtendedFieldURI PropertySetId="\#(propertySetID)" PropertyId="\#(propertyID)" PropertyType="Integer"/>"#

    /// Outlook's "Allow forwarding" switch, stored inverted as a named Boolean "DoNotForward" in
    /// the public-strings property set. Like the charm, not in the EWS documentation and unproven
    /// on the user's server until a real meeting goes out.
    static let doNotForwardURI = #"<t:ExtendedFieldURI DistinguishedPropertySetId="PublicStrings" PropertyName="DoNotForward" PropertyType="Boolean"/>"#

    /// SF Symbols as close to OWA's glyphs as the set has.
    var symbol: String {
        switch self {
        case .cat: return "cat.fill"
        case .dog: return "dog.fill"
        case .plane: return "airplane"
        case .document: return "doc.text.fill"
        case .firstAid: return "cross.case.fill"
        case .trophy: return "trophy.fill"
        case .home: return "house.fill"
        case .pill: return "pills.fill"
        case .luggage: return "briefcase.fill"
        case .cup: return "cup.and.saucer.fill"
        case .group: return "person.2.fill"
        case .timer: return "stopwatch.fill"
        case .music: return "music.note"
        case .shopping: return "cart.fill"
        case .car: return "car.fill"
        case .star: return "star.fill"
        case .notes: return "note.text"
        case .person: return "person.fill"
        case .balloon: return "balloon.fill"
        case .forkKnife: return "fork.knife"
        case .heart: return "heart.fill"
        case .soccer: return "soccerball"
        case .movie: return "movieclapper.fill"
        case .chart: return "chart.line.uptrend.xyaxis"
        case .books: return "books.vertical.fill"
        case .cake: return "birthday.cake.fill"
        case .tv: return "tv.fill"
        case .travel: return "suitcase.fill"
        case .package: return "shippingbox.fill"
        case .promotion: return "tag.fill"
        case .ticket: return "ticket.fill"
        case .hotel: return "building.2.fill"
        case .creditCard: return "creditcard.fill"
        }
    }

    var label: String {
        switch self {
        case .firstAid: return "First aid"
        case .forkKnife: return "Food"
        case .tv: return "TV"
        case .creditCard: return "Credit card"
        default: return String(describing: self).capitalized
        }
    }
}
