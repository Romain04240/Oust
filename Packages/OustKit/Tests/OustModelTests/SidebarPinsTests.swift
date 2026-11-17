import Foundation
import OustCore
import Testing
@testable import OustModel

struct SidebarPinsTests {
    @Test("Épingler réordonne les outils sans les dupliquer")
    func ordering() {
        var preferences = Preferences(projectRoots: [])
        let tools: [AppSection] = [.applications, .system, .clouds]
        preferences.toggleSidebarPin(.clouds)
        preferences.toggleSidebarPin(.system)
        preferences.toggleSidebarPin(.overview)
        #expect(preferences.orderedSidebarTools(tools) == [.clouds, .system, .applications])
        preferences.toggleSidebarPin(.clouds)
        #expect(preferences.orderedSidebarTools(tools) == [.system, .applications, .clouds])
    }

    @Test("Les favoris sont relus dans leur ordre et les valeurs inconnues sont ignorées")
    func persistence() {
        let defaults = MemoryDefaults()
        let home = FileManager.default.temporaryDirectory
        #expect(Preferences.load(home: home, defaults: defaults).sidebarPins.isEmpty)
        defaults.set(["clouds", "inconnu", "system", "clouds", "cart"], forKey: Preferences.sidebarPinsKey)
        var preferences = Preferences.load(home: home, defaults: defaults)
        #expect(preferences.sidebarPins == [.clouds, .system])
        preferences.toggleSidebarPin(.system)
        preferences.save(defaults: defaults)
        #expect(Preferences.load(home: home, defaults: defaults).sidebarPins == [.clouds])
    }
}
