import CoreServices
import Foundation
import OustCore

/// La famille du binaire principal, d’après les métadonnées déjà indexées.
public enum AppArchitecture: String, CaseIterable, Sendable {
    case appleSilicon
    case intel
    case universal
    case legacy

    public var localizationKey: String { "applications.architecture.\(rawValue)" }

    public static func indexed(for url: URL) async -> Self? {
        await checkStorageIO {
            guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
                  let values = MDItemCopyAttribute(item, kMDItemExecutableArchitectures) as? [String] else {
                return nil
            }
            return classify(values)
        } ?? nil
    }

    static func classify(_ values: [String]) -> Self? {
        let architectures = Set(values.map { $0.lowercased() })
        let known: Set<String> = ["arm64", "arm64e", "x86_64", "x86_64h", "i386", "ppc", "ppc64"]
        guard !architectures.isEmpty, architectures.isSubset(of: known) else { return nil }
        let arm = !architectures.isDisjoint(with: ["arm64", "arm64e"])
        let intel64 = !architectures.isDisjoint(with: ["x86_64", "x86_64h"])
        switch (arm, intel64) {
        case (true, true): return .universal
        case (true, false): return .appleSilicon
        case (false, true): return .intel
        case (false, false): return .legacy
        }
    }
}
