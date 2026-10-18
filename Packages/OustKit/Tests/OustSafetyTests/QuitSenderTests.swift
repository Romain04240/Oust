import Foundation
import Testing
@testable import OustSafety

@Suite("Qui demande de quitter")
struct QuitSenderTests {
    @Test("Réglages Système et ses panneaux sont reconnus")
    func systemSettings() {
        #expect(QuitSender.isSystemSettings(executable: "/System/Applications/System Settings.app/Contents/MacOS/System Settings"))
        #expect(QuitSender.isSystemSettings(
            executable: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension"))
    }

    @Test("La fermeture de session et les scripts ne rouvrent pas l'app")
    func others() {
        #expect(!QuitSender.isSystemSettings(executable: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"))
        #expect(!QuitSender.isSystemSettings(executable: "/usr/bin/osascript"))
        #expect(!QuitSender.isSystemSettings(executable: "/Applications/System Settings.app/Contents/MacOS/System Settings"))
    }

    @Test("Le processus courant a un exécutable, un PID absent n'en a pas")
    func executable() {
        #expect(QuitSender.executable(of: getpid()) != nil)
        #expect(QuitSender.executable(of: 0) == nil)
    }
}
