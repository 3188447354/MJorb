import Testing
@testable import Seal

@Suite("设置页加载代次")
struct SettingsLoadGenerationGateTests {
    @Test
    func olderBackgroundLoadCannotPublishAfterANewerLoadBegins() {
        var gate = SettingsLoadGenerationGate()
        let firstLoad = gate.issue()
        let secondLoad = gate.issue()

        #expect(gate.accepts(secondLoad))
        #expect(gate.accepts(firstLoad) == false)
    }
}
