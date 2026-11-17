import Testing
@testable import OustUninstall

struct AppArchitectureTests {
    @Test("Les architectures indexées distinguent le binaire natif, Intel et universel")
    func modernArchitectures() {
        #expect(AppArchitecture.classify(["arm64e"]) == .appleSilicon)
        #expect(AppArchitecture.classify(["x86_64", "i386"]) == .intel)
        #expect(AppArchitecture.classify(["ARM64", "x86_64"]) == .universal)
    }

    @Test("L’absence de métadonnées et les valeurs inconnues restent indéterminées")
    func unknownArchitectures() {
        #expect(AppArchitecture.classify([]) == nil)
        #expect(AppArchitecture.classify(["arm64", "unknown"]) == nil)
        #expect(AppArchitecture.classify(["i386", "ppc"]) == .legacy)
    }
}
