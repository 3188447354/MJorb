import Foundation

enum ErrorKnowledgeKind: String, Codable, Equatable, Sendable {
    case failure
    case warning
    case diagnostic
}

enum ErrorKnowledgeConfidence: String, Codable, Equatable, Sendable {
    case confirmed
    case conditional
    case unknown

    var title: String {
        switch self {
        case .confirmed: "已确认"
        case .conditional: "需要进一步确认"
        case .unknown: "尚未能确认原因"
        }
    }
}

struct ErrorKnowledgeAction: Codable, Equatable, Identifiable, Sendable {
    let title: String
    let route: String?

    var id: String { "\(title)|\(route ?? \"\")" }
}

struct ErrorKnowledgeEntry: Codable, Equatable, Identifiable, Sendable {
    let code: String
    let kind: ErrorKnowledgeKind
    let confidence: ErrorKnowledgeConfidence
    let summary: String
    let evidence: [String]
    let notEvidenceOf: [String]
    let actions: [ErrorKnowledgeAction]
    let supportData: [String]
    let source: [String]

    var id: String { code }
    var confidenceTitle: String { confidence.title }

    init(
        code: String,
        kind: ErrorKnowledgeKind,
        confidence: ErrorKnowledgeConfidence,
        summary: String,
        evidence: [String] = [],
        notEvidenceOf: [String] = [],
        actions: [ErrorKnowledgeAction],
        supportData: [String] = [],
        source: [String]
    ) {
        self.code = code
        self.kind = kind
        self.confidence = confidence
        self.summary = summary
        self.evidence = evidence
        self.notEvidenceOf = notEvidenceOf
        self.actions = actions
        self.supportData = supportData
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case code, kind, confidence, summary, evidence, notEvidenceOf, actions, supportData, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        kind = try container.decode(ErrorKnowledgeKind.self, forKey: .kind)
        confidence = try container.decode(ErrorKnowledgeConfidence.self, forKey: .confidence)
        summary = try container.decode(String.self, forKey: .summary)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        notEvidenceOf = try container.decodeIfPresent([String].self, forKey: .notEvidenceOf) ?? []
        actions = try container.decode([ErrorKnowledgeAction].self, forKey: .actions)
        supportData = try container.decodeIfPresent([String].self, forKey: .supportData) ?? []
        source = try container.decode([String].self, forKey: .source)
    }

    static func unknown(code: String) -> Self {
        Self(
            code: code,
            kind: .failure,
            confidence: .unknown,
            summary: "此错误码尚未建立可验证的专属结论。",
            notEvidenceOf: ["无法仅凭错误码判断真实原因", "无法仅凭此信息判断账户、证书、描述文件或设备连接是否失效"],
            actions: [
                ErrorKnowledgeAction(title: "导出日志", route: "logs"),
                ErrorKnowledgeAction(title: "查看官网帮助", route: "website")
            ],
            supportData: ["错误码", "操作时间", "导出的 Seal 日志"],
            source: ["离线错误帮助兜底"]
        )
    }
}

private struct ErrorKnowledgeCatalog: Decodable {
    let schemaVersion: Int
    let entries: [ErrorKnowledgeEntry]
}

enum ErrorKnowledgeStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case duplicateCode(String)
}

struct ErrorKnowledgeStore: Sendable {
    private let entriesByCode: [String: ErrorKnowledgeEntry]

    init(data: Data) throws {
        let catalog = try JSONDecoder().decode(ErrorKnowledgeCatalog.self, from: data)
        guard catalog.schemaVersion == 1 else {
            throw ErrorKnowledgeStoreError.unsupportedSchemaVersion(catalog.schemaVersion)
        }

        var entriesByCode: [String: ErrorKnowledgeEntry] = [:]
        for entry in catalog.entries {
            guard entriesByCode.updateValue(entry, forKey: entry.code) == nil else {
                throw ErrorKnowledgeStoreError.duplicateCode(entry.code)
            }
        }
        self.entriesByCode = entriesByCode
    }

    private init(entriesByCode: [String: ErrorKnowledgeEntry]) {
        self.entriesByCode = entriesByCode
    }

    func entry(for code: String) -> ErrorKnowledgeEntry? {
        entriesByCode[code]
    }

    func help(for code: String) -> ErrorKnowledgeEntry {
        entry(for: code) ?? .unknown(code: code)
    }

    var entries: [ErrorKnowledgeEntry] {
        entriesByCode.values.sorted { $0.code < $1.code }
    }

    static func bundled() -> Self {
        guard let url = Bundle.main.url(forResource: "help-index", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let store = try? Self(data: data) else {
            return Self(entriesByCode: [:])
        }
        return store
    }
}
