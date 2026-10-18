import Foundation
import OustAgent

// `oust` : l'interface d'Oust! pour les agents IA et le terminal. Toute la
// logique vit dans OustAgent, testée là-bas ; ce fichier ne fait que lancer.

OustCommand.relaunchFromRealPathIfNeeded()
exit(await OustCommand.main(Array(CommandLine.arguments.dropFirst())))
