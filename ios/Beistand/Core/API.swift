import Foundation

/// Thin client for the Beistand backend.
struct API {
    static let shared = API()
    private var base: URL { AppStore.shared.backendURL }

    struct Incident: Decodable, Equatable {
        let id: String
        let trigger: String
        let state: String
        let deadline: Date?
        let show_bystander_card: Bool
        let offer_emergency_call: Bool
        let acked_by: String?
    }

    struct Reading: Decodable {
        let readable: Bool
        let retake_hint: String?
        let sender: String?
        let wants: String?
        let amount: String?
        let deadline: String?
        let spoken: String
    }

    struct ScamVerdict: Decodable {
        let level: String
        let patterns: [String]
        let spoken: String
    }

    struct Warnings: Decodable {
        struct D: Decodable { let temperature_c: Double?; let tip: String }
        let data: D
        let age_s: Int
    }

    func putProfile(_ p: Profile) async throws {
        struct Body: Encodable { let name: String; let language: String; let modes: [String]; let contacts: [EmergencyContact] }
        _ = try await send("PUT", "users/\(p.userId)/profile",
                           Body(name: p.name, language: Lang.code, modes: p.modes.map(\.rawValue), contacts: p.contacts))
    }

    func startIncident(userId: String, trigger: String, lat: Double?, lon: Double?) async throws -> Incident {
        struct Loc: Encodable { let lat: Double; let lon: Double }
        struct Body: Encodable { let user_id: String; let trigger: String; let location: Loc? }
        let loc = (lat != nil && lon != nil) ? Loc(lat: lat!, lon: lon!) : nil
        return try await decode(send("POST", "incidents", Body(user_id: userId, trigger: trigger, location: loc)))
    }

    func incident(_ id: String) async throws -> Incident { try await decode(send("GET", "incidents/\(id)", Empty?.none)) }
    func personOK(_ id: String) async throws -> Incident { try await decode(send("POST", "incidents/\(id)/ok", Empty?.none)) }
    func confirmEmergency(_ id: String, by: String) async throws -> Incident {
        struct B: Encodable { let confirmed_by: String }
        return try await decode(send("POST", "incidents/\(id)/confirm-emergency", B(confirmed_by: by)))
    }

    func read(jpeg: Data, lang: String) async throws -> Reading {
        struct B: Encodable { let image_b64: String; let media_type: String; let lang: String }
        return try await decode(send("POST", "read", B(image_b64: jpeg.base64EncodedString(), media_type: "image/jpeg", lang: lang)))
    }

    func scamCheck(_ text: String, lang: String) async throws -> ScamVerdict {
        struct B: Encodable { let text: String; let lang: String }
        return try await decode(send("POST", "scam-check", B(text: text, lang: lang)))
    }

    func warnings(lat: Double, lon: Double) async throws -> Warnings {
        try await decode(send("GET", "warnings?lat=\(lat)&lon=\(lon)&lang=\(Lang.code)", Empty?.none))
    }

    // MARK: plumbing
    private struct Empty: Encodable {}

    private func send<B: Encodable>(_ method: String, _ path: String, _ body: B?) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        req.timeoutInterval = 60
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s) ?? Date()
        }
        return try d.decode(T.self, from: data)
    }
}

extension API {
    func updateLocation(_ id: String, lat: Double, lon: Double) async throws -> Data {
        var req = URLRequest(url: URL(string: "incidents/\(id)/location", relativeTo: AppStore.shared.backendURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["lat": lat, "lon": lon])
        return try await URLSession.shared.data(for: req).0
    }
}
