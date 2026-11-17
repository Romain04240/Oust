import Foundation
import Testing
@testable import OustWatch

struct BatterySummaryTests {
    @Test("Le rapport d’alimentation distingue capacité maximale et cycles")
    func capacityAndCycles() throws {
        let result = try #require(BatterySummary.parse(report("""
            {"sppower_battery_cycle_count": 402, "sppower_battery_health_maximum_capacity": "83\u{00A0}%"}
            """)))
        #expect(result.maximumCapacity == 83)
        #expect(result.cycleCount == 402)
    }

    @Test("Une mesure invalide n’efface pas la mesure disponible")
    func partialReport() throws {
        let result = try #require(BatterySummary.parse(report("""
            {"sppower_battery_cycle_count": true, "sppower_battery_health_maximum_capacity": "94%"}
            """)))
        #expect(result.maximumCapacity == 94)
        #expect(result.cycleCount == nil)
        let zeroCycles = try #require(BatterySummary.parse(report("""
            {"sppower_battery_cycle_count": 0, "sppower_battery_health_maximum_capacity": "120%"}
            """)))
        #expect(zeroCycles.maximumCapacity == nil)
        #expect(zeroCycles.cycleCount == 0)
    }

    @Test("Un rapport sans batterie ou sans donnée valide n’affiche aucun indicateur")
    func missingBattery() {
        #expect(BatterySummary.parse(Data(#"{"SPPowerDataType":[{"_name":"AC Power"}]}"#.utf8)) == nil)
        #expect(BatterySummary.parse(report(#"{"sppower_battery_cycle_count": -1}"#)) == nil)
        #expect(BatterySummary.parse(Data("illisible".utf8)) == nil)
    }

    private func report(_ battery: String) -> Data {
        Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":\#(battery)}]}"#.utf8)
    }
}
