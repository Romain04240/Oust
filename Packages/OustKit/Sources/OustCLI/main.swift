import Foundation
import OustAgent
import OustDeviceRelay

// Internal read-only worker: before relaunch or creation of any AgentService.
if Array(CommandLine.arguments.dropFirst()) == ["--internal-watch-battery-snapshot-v1"] {
    exit(oust_watch_relay_snapshot())
}

// `oust` : l'interface d'Oust! pour les agents IA et le terminal. Toute la
// logique vit dans OustAgent, testée là-bas ; ce fichier ne fait que lancer.

OustCommand.relaunchFromRealPathIfNeeded()
exit(await OustCommand.main(Array(CommandLine.arguments.dropFirst())))
