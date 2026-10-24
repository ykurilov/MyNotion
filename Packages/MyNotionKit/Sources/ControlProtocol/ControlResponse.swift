import Foundation

/// Итоговая строка ответа (contracts/protocol.md, «Ответ»).
public struct ControlResponse: Sendable, Hashable, Codable {
    public var id: String
    public var ok: Bool
    public var data: ControlJSON?
    public var error: ControlError?
    public var warnings: [ControlWarning]
    /// Одна-две строки для человека — только на запрос с `human`.
    public var text: String?

    public init(id: String, ok: Bool, data: ControlJSON? = nil, error: ControlError? = nil, warnings: [ControlWarning] = [],
                text: String? = nil) {
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
        self.warnings = warnings
        self.text = text
    }

    public static func success(_ id: String, _ data: ControlJSON, warnings: [ControlWarning] = [], text: String? = nil) -> ControlResponse {
        ControlResponse(id: id, ok: true, data: data, warnings: warnings, text: text)
    }

    public static func failure(_ id: String, _ error: ControlError, warnings: [ControlWarning] = []) -> ControlResponse {
        ControlResponse(id: id, ok: false, error: error, warnings: warnings)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, data, error, warnings, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        ok = try container.decode(Bool.self, forKey: .ok)
        data = try container.decodeIfPresent(ControlJSON.self, forKey: .data)
        error = try container.decodeIfPresent(ControlError.self, forKey: .error)
        warnings = try container.decodeIfPresent([ControlWarning].self, forKey: .warnings) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(error, forKey: .error)
        if !warnings.isEmpty { try container.encode(warnings, forKey: .warnings) }
        try container.encodeIfPresent(text, forKey: .text)
    }
}

/// Ход долгой команды: `{"id":"…","progress":{"done":120,"total":900,"stage":"Страницы"}}`.
public struct ControlProgress: Sendable, Hashable, Codable {
    public var done: Int
    public var total: Int?
    public var stage: String?

    public init(done: Int, total: Int? = nil, stage: String? = nil) {
        self.done = done
        self.total = total
        self.stage = stage
    }
}

/// Строка ответа: ход или итог.
public enum ControlResponseLine: Sendable, Hashable {
    case progress(id: String, ControlProgress)
    case result(ControlResponse)

    public var isFinal: Bool {
        if case .result = self { true } else { false }
    }
}

extension ControlResponseLine: Codable {
    private enum ProgressKeys: String, CodingKey {
        case id, progress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ProgressKeys.self)
        if let progress = try container.decodeIfPresent(ControlProgress.self, forKey: .progress) {
            self = .progress(id: try container.decodeIfPresent(String.self, forKey: .id) ?? "", progress)
        } else {
            self = .result(try ControlResponse(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .progress(let id, let progress):
            var container = encoder.container(keyedBy: ProgressKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(progress, forKey: .progress)
        case .result(let response):
            try response.encode(to: encoder)
        }
    }
}
