import Foundation

/// Les dates des snapshots Time Machine locaux, telles que le démon les admet.
///
/// Un double de `LocalSnapshot.isValidDate` (OustCore), plus strict, et voulu :
/// l'application valide avant de demander, le démon revalide avant d'agir, sans
/// faire confiance à ce qu'on lui envoie. Les tests vérifient qu'ils ne se
/// contredisent pas sur ce que l'application peut produire.
public enum SnapshotDates {

    public static let timeMachinePrefix = "com.apple.TimeMachine."
    public static let localSuffix = ".local"

    /// `AAAA-MM-JJ-HHMMSS`, en chiffres ASCII, mois, jour et heure plausibles.
    ///
    /// La chaîne devient un argument de `tmutil deletelocalsnapshots`, lancé en
    /// root. Elle n'y entre que sous cette forme exacte : `tmutil` accepte aussi
    /// un point de montage à la place d'une date, et `/` lui ferait supprimer
    /// tous les snapshots du volume.
    ///
    /// Comparée octet par octet : dix-sept octets, chacun un chiffre ASCII ou un
    /// tiret à sa place. Aucun chiffre d'une autre écriture, aucun caractère
    /// combinant ni espace ne peut s'y glisser.
    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let shape = Array("dddd-dd-dd-dddddd".utf8)
        guard bytes.count == shape.count else { return false }
        for (byte, expected) in zip(bytes, shape) {
            if expected == UInt8(ascii: "d") {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return false }
            } else if byte != expected {
                return false
            }
        }
        func number(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        return (1...12).contains(number(5..<7))
            && (1...31).contains(number(8..<10))
            && number(11..<13) < 24
            && number(13..<15) < 60
            && number(15..<17) < 60
    }

    /// Le nom exact du snapshot Time Machine local de cette date.
    public static func snapshotName(for date: String) -> String {
        timeMachinePrefix + date + localSuffix
    }

    /// Les dates des snapshots Time Machine locaux dans une sortie de
    /// `tmutil listlocalsnapshots`.
    ///
    /// Une ligne qui n'est pas exactement `com.apple.TimeMachine.<date>.local`
    /// est ignorée : les snapshots de mise à jour (`com.apple.os.update-…`), qui
    /// servent au système, n'y figurent donc jamais.
    public static func timeMachineDates(inListing output: String) -> Set<String> {
        var dates = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(timeMachinePrefix), name.hasSuffix(localSuffix),
                  name.count > timeMachinePrefix.count + localSuffix.count else { continue }
            let date = String(name.dropFirst(timeMachinePrefix.count).dropLast(localSuffix.count))
            if isValid(date) { dates.insert(date) }
        }
        return dates
    }
}
