import Foundation
import OustHelperDaemon
import OustHelperContract

// `oust-helper` — lancé par launchd au premier message d'Oust!, jamais au
// démarrage du Mac. Tout ce qu'il fait est dans OustHelperDaemon ; ce fichier
// ne fait que le brancher sur son service Mach (docs/adr/0001).

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

// Une minute sans demande et il s'en va : launchd le relancera au besoin.
let idle = IdleMonitor(idle: 60) { exit(EXIT_SUCCESS) }
let service = HelperService(tool: SystemSnapshotTool(), backups: SystemBackupTool(), version: version,
                            activity: idle)

let listener = NSXPCListener(machServiceName: HelperContract.machServiceName)
// Posée sur l'écouteur en plus de chaque connexion : un appelant qui n'est pas
// Oust! est écarté avant même d'être présenté au service.
listener.setConnectionCodeSigningRequirement(HelperContract.clientRequirement)
listener.delegate = service
listener.resume()

dispatchMain()
