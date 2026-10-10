import Foundation
import Testing
@testable import Seal

struct ErrorKnowledgeStoreTests {
    @Test
    func cataloguedConditionalCodeShowsItsLimit() throws {
        let store = try ErrorKnowledgeStore(data: fixtureData)

        let entry = try #require(store.entry(for: "SEAL-PROFILE-363"))

        #expect(entry.confidence == .conditional)
        #expect(entry.notEvidenceOf.contains("描述文件注入失败"))
        #expect(entry.confidenceTitle == "需要进一步确认")
    }

    @Test
    func unknownCodeDoesNotInventACause() throws {
        let store = try ErrorKnowledgeStore(data: fixtureData)

        let entry = store.help(for: "SEAL-UNKNOWN-999")

        #expect(entry.confidence == .unknown)
        #expect(entry.actions.map(\.title) == ["导出日志", "查看官网帮助"])
        #expect(entry.notEvidenceOf.contains("无法仅凭错误码判断真实原因"))
    }

    private var fixtureData: Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "entries": [
                {
                  "code": "SEAL-PROFILE-363",
                  "kind": "diagnostic",
                  "confidence": "conditional",
                  "summary": "设备端核验未确认。",
                  "notEvidenceOf": ["描述文件注入失败"],
                  "actions": [{"title": "等待最终结果"}],
                  "source": ["Seal/Core/Signing/SigningCoordinator.swift"]
                }
              ]
            }
            """.utf8
        )
    }
}
