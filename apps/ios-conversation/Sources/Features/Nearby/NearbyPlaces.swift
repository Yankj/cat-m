import Foundation
import MapKit
import CoreLocation

/// places_search executor: real When-In-Use location → MKLocalSearch (3–5) → MKDirections ETA per result.
/// No location → honest error (never a hardcoded city). Taste / travel-mode memories shape the query and are cited.
@MainActor enum NearbyPlaces {
    static func search(call: DeviceCall) async -> DeviceCallResult {
        let query = call.args["query"]?.text ?? ""
        func fail(_ reason: String, _ message: String) -> DeviceCallResult {
            .init(call_id: call.call_id, status: .error, data: ["reason": .string(reason), "retryable": .bool(false), "message": .string(message)])
        }
        guard !query.isEmpty else { return fail("invalid_query", "Empty query.") }
        var snaps: [MemoryLibrarySnapshot] = []
        if let b = MemoryLibraryHub.backend, let s = try? await b.load() { snaps.append(s) }
        if MemoryLibraryHub.backend !== MemoryLibraryHub.local, let s = try? await MemoryLibraryHub.local.load() { snaps.append(s) }
        let prefs = NearbyRules.preferences(in: snaps)
        let argMode = call.args["mode"]?.text ?? ""
        let mode = NearbyRules.effectiveMode(arg: argMode, prefs: prefs)
        if CLLocationManager().authorizationStatus == .notDetermined { _ = await ProactiveEngine.shared.requestLocationAccess() }   // When-In-Use prompt
        guard let origin = await ProactiveEngine.requestCurrentCoordinate() else {
            return fail("location_unavailable", "没有拿到你的当前位置（未授权定位或定位超时），所以没法查附近。请在 设置 › 隐私 › 定位 打开 Catpaw 的「使用期间」后再试。")
        }
        // Radius widens once when fewer than NearbyRules.minResults came back.
        var found: [MKMapItem] = []
        for radius in NearbyRules.radii {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = query
            req.region = MKCoordinateRegion(center: origin, latitudinalMeters: radius, longitudinalMeters: radius)
            req.resultTypes = .pointOfInterest
            found = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
            if !NearbyRules.needsWiderSearch(found.count) { break }
        }
        guard !found.isEmpty else {
            return .init(call_id: call.call_id, status: .ok, data: ["places": .array([]), "count": .number(0), "why": .string("附近 8 公里内没搜到「\(query)」")])
        }
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let cands = found.map { NearbyRules.Candidate(name: $0.name ?? "", category: $0.pointOfInterestCategory?.rawValue ?? "",
            distance: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude).distance(from: here)) }
        let ranked = NearbyRules.rank(cands, prefs: prefs).map { found[$0] }   // taste memory changes the order
        let transport: MKDirectionsTransportType = mode == .driving ? .automobile : mode == .transit ? .transit : .walking
        var rows: [DeviceCallValue] = []
        for item in ranked.prefix(NearbyRules.maxResults) {
            let c = item.placemark.coordinate
            let dReq = MKDirections.Request()
            dReq.source = MKMapItem(placemark: MKPlacemark(coordinate: origin)); dReq.destination = item; dReq.transportType = transport
            var eta: Double? = nil
            if transport == .transit { eta = (try? await MKDirections(request: dReq).calculateETA())?.expectedTravelTime }
            else { eta = (try? await MKDirections(request: dReq).calculate())?.routes.first?.expectedTravelTime }
            let name = item.name ?? query
            var row: [String: DeviceCallValue] = [
                "name": .string(name), "address": .string(item.placemark.title ?? ""),
                "distance_m": .number((CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))).rounded()),
                "maps_url": .string(NearbyRules.mapsURL(lat: c.latitude, lng: c.longitude, name: name, mode: mode))]
            if let eta { row["eta_min"] = .number(max(1, (eta / 60).rounded())) }
            if let phone = item.phoneNumber, let tel = NearbyRules.telURL(phone) { row["phone"] = .string(phone); row["tel_url"] = .string(tel) }
            rows.append(.object(row))
        }
        let why = NearbyRules.why(prefs: prefs, mode: mode, modeFromArg: NearbyRules.Mode(rawValue: argMode) != nil, originNote: "起点是你当前的真实位置")
        return .init(call_id: call.call_id, status: .ok, data: ["places": .array(rows), "count": .number(Double(rows.count)), "mode": .string(mode.rawValue), "why": .string(why),
            "memory_ids": .list(prefs.cited.map(\.id))])
    }
}
