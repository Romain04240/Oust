import Foundation
import Testing
@testable import OustVolume

@Suite("Détail APFS du seul conteneur concerné")
struct APFSStorageTests {
    func fixture(volumes: [[String: Any]]? = nil, free: Any = 200) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Containers": [
            ["ContainerReference": "disk9", "CapacityCeiling": 1000, "CapacityFree": 999, "Volumes": []],
            ["ContainerReference": "disk3", "CapacityCeiling": 1000, "CapacityFree": free,
             "Volumes": volumes ?? [
                ["DeviceIdentifier": "disk3s1", "Name": "System", "Roles": ["System"], "CapacityInUse": 150],
                ["DeviceIdentifier": "disk3s5", "Name": "Data", "Roles": ["Data"], "CapacityInUse": 600]
             ]]
        ]], format: .binary, options: 0)
    }

    @Test("Les volumes et métadonnées viennent du conteneur sélectionné, pas d'une image montée")
    func selectedContainer() throws {
        let data = try fixture()
        let usage = try #require(APFSContainerUsage.parse(data, reference: "disk3", selectedVolume: "disk3s5"))
        #expect(usage.volumes.count == 2)
        #expect(usage.metadataBytes == 50)
        #expect(usage.volumes.first?.id == "disk3s5")
        #expect(usage.volumes.last?.roleKey == "storage.apfs.system")
        #expect(APFSContainerUsage.parse(data, reference: "disk3", selectedVolume: "disk9s1") == nil)
    }

    @Test("Une mesure absente, négative, dupliquée ou booléenne n'est pas inventée")
    func malformed() throws {
        for amount: Any in [-1, true, 2000] {
            let data = try fixture(volumes: [["DeviceIdentifier": "disk3s5", "Name": "Data", "CapacityInUse": amount]])
            #expect(APFSContainerUsage.parse(data, reference: "disk3", selectedVolume: "disk3s5") == nil)
        }
        let repeated: [String: Any] = ["DeviceIdentifier": "disk3s5", "Name": "Data", "CapacityInUse": 100]
        let duplicateData = try fixture(volumes: [repeated, repeated])
        #expect(APFSContainerUsage.parse(duplicateData, reference: "disk3", selectedVolume: "disk3s5") == nil)
        #expect(APFSContainerUsage.parse(Data(), reference: "disk3", selectedVolume: "disk3s5") == nil)
        let badFree = try fixture(free: 2000)
        #expect(APFSContainerUsage.parse(badFree, reference: "disk3", selectedVolume: "disk3s5") == nil)
    }

    @Test("Des mesures décalées ne produisent pas une taille négative de métadonnées")
    func inconsistentSamples() throws {
        let data = try fixture(free: 500)
        let usage = try #require(APFSContainerUsage.parse(data, reference: "disk3", selectedVolume: "disk3s5"))
        #expect(usage.metadataBytes == nil)
        #expect(usage.volumes.count == 2)
    }
}
