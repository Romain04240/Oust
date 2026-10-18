import Foundation
import Testing
@testable import OustAgent

/// Les clés que l'interface des agents construit à l'exécution
/// (`agent.refusal.\(rawValue)`, `explain.\(partie)`) échappent au lint, qui ne
/// lit que les littéraux : on les vérifie ici, dans la source du catalogue.
@Suite("Le catalogue couvre les clés de l'interface des agents")
struct AgentCatalogTests {
    static let catalog: Set<String> = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OustLocalization/Resources/Localizable.xcstrings")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Set((object?["strings"] as? [String: Any] ?? [:]).keys)
    }()

    @Test("Refus, verdicts et parties d'une explication")
    func builtKeys() {
        let keys = AgentRefusal.allCases.map(\.localizationKey)
            + ["agent.verdict.allowed", "agent.verdict.needsAllowReview"]
            + ["what", "back", "method", "protected", "where", "sizes"].map { "explain.\($0)" }
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }
}
