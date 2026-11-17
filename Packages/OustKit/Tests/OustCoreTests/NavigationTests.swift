import Foundation
import Testing
@testable import OustCore

@Suite("Où mène un clic venu d'ailleurs")
struct NavigationTests {
    @Test("Une notification retrouve sa section ou son onglet des Réglages", arguments: [
        Destination.section(.overview), .section(.history), .section(.cart),
        .settings(.general), .settings(.analysis), .settings(.watch), .settings(.advanced),
    ])
    func roundTrip(_ destination: Destination) {
        let userInfo: [AnyHashable: Any] = destination.userInfo.reduce(into: [:]) { $0[$1.key] = $1.value }
        #expect(Destination(userInfo: userInfo) == destination)
    }

    @Test("Ce qu'on ne reconnaît pas mène à la vue d'ensemble, jamais nulle part")
    func unknown() {
        #expect(Destination(userInfo: [:]) == .section(.overview))
        // L'ancienne section Réglages, devenue une fenêtre : plus une section.
        #expect(Destination(userInfo: ["section": "settings"]) == .section(.overview))
        #expect(Destination(userInfo: ["settingsTab": "nowhere"]) == .section(.overview))
        #expect(Destination(userInfo: ["section": 42]) == .section(.overview))
    }

    @Test("Un onglet inconnu n'empêche pas de retrouver la section")
    func fallsBackToSection() {
        #expect(Destination(userInfo: ["settingsTab": "nowhere", "section": "history"]) == .section(.history))
    }

    @Test("Les Réglages ne sont plus une section de la fenêtre")
    func settingsIsNotASection() {
        #expect(AppSection(rawValue: "settings") == nil)
        #expect(SettingsTab.allCases.map(\.rawValue) == ["general", "analysis", "watch", "battery", "advanced"])
    }
}
