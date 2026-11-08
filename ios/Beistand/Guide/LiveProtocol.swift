import Foundation

/// Gemini Live API messages (BidiGenerateContent over WebSocket).
/// Kept free of networking and audio so it can be unit-tested.
enum LiveProtocol {
    static func url(token: String) -> URL {
        // Ephemeral tokens use the "Constrained" endpoint with access_token.
        var c = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained")!
        c.queryItems = [URLQueryItem(name: "access_token", value: token)]
        return c.url!
    }

    /// `resumeHandle`: continue an earlier session (same conversation) after a disconnect.
    /// Sliding-window compression keeps long walks inside the context limit.
    static func setup(model: String, systemPrompt: String, tools: [[String: Any]], language: String,
                      resumeHandle: String? = nil) -> Data {
        let modelName = model.hasPrefix("models/") ? model : "models/\(model)"
        var resumption: [String: Any] = [:]
        if let resumeHandle { resumption["handle"] = resumeHandle }
        let msg: [String: Any] = ["setup": [
            "sessionResumption": resumption,
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
            "model": modelName,
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["languageCode": language],
            ],
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "tools": tools,
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
        ]]
        return json(msg)
    }

    /// 16 kHz, 16-bit little-endian mono PCM.
    static func audio(_ pcm: Data) -> Data {
        json(["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    static func video(_ jpeg: Data) -> Data {
        json(["realtimeInput": ["video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]])
    }

    /// Text into the conversation. `respond: false` only adds context, the model stays quiet.
    static func text(_ text: String, respond: Bool) -> Data {
        json(["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": respond]])
    }

    static func toolResponse(id: String, name: String, response: [String: Any]) -> Data {
        json(["toolResponse": ["functionResponses": [["id": id, "name": name, "response": response]]]])
    }

    enum Event: Equatable {
        case setupComplete
        case audio(Data)                 // 24 kHz 16-bit PCM
        case guideText(String)           // transcription of what the guide said
        case personText(String)          // transcription of what the person said
        case turnComplete
        case interrupted
        case toolCall(id: String, name: String, args: [String: String])
        case goAway(timeLeft: String?)        // the server will close soon: reconnect now
        case resumeHandle(String)             // latest handle to resume this conversation
    }

    static func parse(_ data: Data) -> [Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Event] = []
        if obj["setupComplete"] != nil { out.append(.setupComplete) }
        if let g = obj["goAway"] as? [String: Any] { out.append(.goAway(timeLeft: g["timeLeft"] as? String)) }
        if let u = obj["sessionResumptionUpdate"] as? [String: Any], u["resumable"] as? Bool == true,
           let h = u["newHandle"] as? String, !h.isEmpty {
            out.append(.resumeHandle(h))
        }
        if let sc = obj["serverContent"] as? [String: Any] {
            if let turn = sc["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                for p in parts {
                    if let inline = p["inlineData"] as? [String: Any], let b64 = inline["data"] as? String,
                       let d = Data(base64Encoded: b64) {
                        out.append(.audio(d))
                    }
                }
            }
            if let t = (sc["outputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty { out.append(.guideText(t)) }
            if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty { out.append(.personText(t)) }
            if sc["interrupted"] as? Bool == true { out.append(.interrupted) }
            if sc["turnComplete"] as? Bool == true { out.append(.turnComplete) }
        }
        if let tc = obj["toolCall"] as? [String: Any], let calls = tc["functionCalls"] as? [[String: Any]] {
            for c in calls {
                let args = (c["args"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                out.append(.toolCall(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "", args: args))
            }
        }
        return out
    }

    private static func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
}

/// When to reconnect a dropped Live session instead of falling back to simple mode. Pure, testable.
struct ResumePolicy {
    var maxAttemptsInARow = 5
    private(set) var attempts = 0

    /// A handle is needed to continue the same conversation.
    mutating func shouldReconnect(hasHandle: Bool) -> Bool {
        guard hasHandle, attempts < maxAttemptsInARow else { return false }
        attempts += 1
        return true
    }

    /// Called when a (re)connection is set up: the next drop starts counting again.
    mutating func connected() { attempts = 0 }
}
