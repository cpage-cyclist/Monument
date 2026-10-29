import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum RouteParserError: LocalizedError {
    case unreadable
    case noPoints

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "That file couldn't be read as a GPX or TCX route."
        case .noPoints: return "That file doesn't contain any route points."
        }
    }
}

/// Reads routes from GPX (Strava, Komoot, etc.) and TCX course files.
public enum RouteParser {
    public static func parse(data: Data, fallbackName: String = "Route") throws -> Route {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || !delegate.points.isEmpty else { throw RouteParserError.unreadable }
        guard delegate.points.count >= 2 else { throw RouteParserError.noPoints }
        // Strava uses non-breaking spaces ("6.89\u{00A0}km"); normalise to plain spaces.
        let name = (delegate.name ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var route = Route(name: name.isEmpty ? fallbackName : name, points: delegate.points)
        route.waypoints = delegate.waypoints
        return route
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var points: [GeoPoint] = []
        var name: String?
        var waypoints: [RouteWaypoint] = []
        /// Inside a `<wpt>`: its position, name and description so far.
        private var wpt: (lat: Double, lon: Double, name: String?, desc: String?)?

        private var text = ""
        private var tcxLat: Double?
        private var tcxLon: Double?
        private var depthInPoint = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch local(elementName) {
            case "trkpt", "rtept":
                depthInPoint = true
                if let lat = attributes["lat"].flatMap(Double.init),
                   let lon = attributes["lon"].flatMap(Double.init) {
                    points.append(GeoPoint(lat: lat, lon: lon))
                }
            case "Position":
                tcxLat = nil
                tcxLon = nil
            case "wpt":
                if let lat = attributes["lat"].flatMap(Double.init),
                   let lon = attributes["lon"].flatMap(Double.init) {
                    wpt = (lat, lon, nil, nil)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local(elementName) {
            case "trkpt", "rtept":
                depthInPoint = false
            case "wpt":
                if let w = wpt, let title = w.name, !title.isEmpty {
                    waypoints.append(RouteWaypoint(title: title, note: w.desc, lat: w.lat, lon: w.lon))
                }
                wpt = nil
            case "desc" where wpt != nil:
                wpt?.desc = value
            case "name", "Name":
                if wpt != nil {
                    wpt?.name = value
                } else if name == nil && !depthInPoint && !value.isEmpty {
                    // First name outside a point is the route name (GPX metadata/trk, TCX Course).
                    name = value
                }
            case "LatitudeDegrees":
                tcxLat = Double(value)
            case "LongitudeDegrees":
                tcxLon = Double(value)
            case "Position":
                if let lat = tcxLat, let lon = tcxLon { points.append(GeoPoint(lat: lat, lon: lon)) }
            default:
                break
            }
            text = ""
        }

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }
}
