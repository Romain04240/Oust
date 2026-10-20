import Foundation
import Testing
import OustCore

@Suite("Délais des outils système")
struct CommandTests {
    @Test("Un descendant gardant un tube ouvert ne retient pas l'appelant")
    func inheritedPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await Command.run("/bin/sh", ["-c", "/bin/sleep 3 & printf done"], timeout: 0.1)
        #expect(clock.now - start < .seconds(2))
        #expect(result.output == "done")
    }

    @Test("Un outil ignorant SIGTERM respecte quand même le délai")
    func ignoresTermination() async {
        let start = ContinuousClock.now
        let result = await Command.run("/bin/sh", ["-c", "trap '' TERM; while :; do /bin/sleep 0.05; done"], timeout: 0.1)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("Les deux sorties sont lues sans bloquer sur un tube plein")
    func largeOutput() async {
        let result = await Command.run("/usr/bin/awk", ["BEGIN { for (i=0; i<50000; i++) { print i; print i > \"/dev/stderr\" } }"], timeout: 5)
        #expect(result.succeeded)
        #expect(result.output.hasSuffix("49999\n"))
        #expect(result.errorOutput.hasSuffix("49999\n"))
    }
}
