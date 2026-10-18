import Foundation
import OustCore

/// Chercher un fichier du cloud par son nom ou son dossier, sans tenir compte
/// de la casse ni des accents, comme la recherche de la barre latérale.
///
/// À l'essai du 18/10/2026, un fichier de 1,2 Mo était au rang 3 650 sur 3 889,
/// introuvable. Les textes sont repliés une fois, à la lecture du cloud :
/// 50 000 fichiers à replier à chaque frappe ralentiraient.
public struct CloudSearch: Sendable {
    private let texts: [String: String]

    public init(_ files: [CloudEntry] = []) {
        texts = Dictionary(files.map { ($0.id, Self.text(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Le filtre d'une recherche ; nil quand elle est vide.
    public func filter(_ query: String) -> (@Sendable (CloudEntry) -> Bool)? {
        let words = ItemFilter.tokens(of: query)
        guard !words.isEmpty else { return nil }
        let texts = texts
        return { file in
            let text = texts[file.id] ?? Self.text(of: file)
            return words.allSatisfy(text.contains)
        }
    }

    /// « facture 2019.pdf », puis « Business », « Comptes » : chaque mot doit
    /// se retrouver dans le nom ou l'un des dossiers.
    static func text(of file: CloudEntry) -> String {
        ItemFilter.fold(([file.name] + file.folder).joined(separator: "\n"))
    }
}
