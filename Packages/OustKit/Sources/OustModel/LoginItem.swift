import Foundation
import OustWatch
import ServiceManagement

/// `SMAppService.mainApp` : l'app elle-même, pas un assistant à côté. C'est
/// macOS qui tient la liste ; Oust! la lit au lieu d'en garder une copie.
/// Ce que dit le statut, et ce qu'on en montre, est dans `OustWatch/LoginItemState`.
@MainActor
enum LoginItem {
    static var status: LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
