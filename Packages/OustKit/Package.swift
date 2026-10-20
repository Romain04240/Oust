// swift-tools-version: 6.2

import PackageDescription

// MARK: - Architecture
//
// Les dépendances ne vont que dans un sens, et SwiftPM le fait respecter : une
// cible qui n'est pas déclarée en dépendance ne peut tout simplement pas être
// importée.
//
//   Feature*        →  Model, DesignSystem, Localization, Core
//   FeatureExplorer →  … et Scan, Sunburst (il dessine l'arborescence elle-même)
//   Model           →  les moteurs ci-dessous (état de l'application, corbeille)
//   Agent           →  Rules, Clean, Safety (la CLI et le serveur MCP des agents),
//                      Model pour les préférences, DesignSystem pour les phrases
//   OustCLI         →  Agent                   (l'exécutable `oust`, rien d'autre)
//   Rules           →  Core, Scan, Safety
//   Clean           →  Core, Safety, Volume
//   Archive         →  Core, Scan, Safety, Clean (l'original part par Clean)
//   Uninstall       →  Core, Scan, Safety
//   LargeFiles      →  Core, Scan, Safety
//   Sunburst        →  Scan
//   Watch           →  Core, Rules (veille : alerte disque bas, règles planifiées)
//   FeatureMenuBar  →  … et Watch (la barre de menus, hors de la fenêtre)
//   Photos          →  Core (PhotoKit et Vision ; jamais le paquet .photoslibrary)
//   Clouds          →  Core, Scan, Safety (les fantômes des nuages, sans réseau)
//   Duplicates      →  Core, Scan
//   Browsers        →  Core
//   Scan            →  Core
//   Volume          →  Core, HelperContract (le client du démon privilégié)
//   HelperDaemon    →  HelperContract (le démon root ne lie rien d'autre)
//   HelperContract  →  rien
//   Safety          →  Core
//   DesignSystem    →  Core, Localization
//   Core            →  rien                    (domaine pur)
//
// Écart assumé avec Markio : les vues ne reçoivent pas des cas d'usage un par
// un mais un `OustModel` commun. Toutes les sections partagent le même panier
// et le même résultat d'analyse ; les découper en modèles indépendants aurait
// obligé à synchroniser six copies d'un même état.

let package = Package(
    name: "OustKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "OustKit", type: .static, targets: [
            "OustCore",
            "OustLocalization",
            "OustDesignSystem",
            "OustScan",
            "OustVolume",
            "OustSafety",
            "OustRules",
            "OustClean",
            "OustDuplicates",
            "OustBrowsers",
            "OustUninstall",
            "OustArchive",
            "OustLargeFiles",
            "OustSunburst",
            "OustWatch",
            "OustPhotos",
            "OustClouds",
            "OustModel",
            "FeatureOverview",
            "FeatureDevAI",
            "FeatureArchive",
            "FeatureExplorer",
            "FeatureLargeFiles",
            "FeatureDuplicates",
            "FeaturePhotos",
            "FeatureClouds",
            "FeatureApplications",
            "FeatureBrowsers",
            "FeatureSystem",
            "FeatureCart",
            "FeatureHistory",
            "FeatureSettings",
            "FeatureSearch",
            "FeatureDisks",
            "FeatureMenuBar",
        ]),
        // Le démon privilégié lie ce produit, et lui seul (docs/adr/0001).
        .library(name: "OustHelperDaemon", targets: ["OustHelperDaemon"]),
        // La CLI et le serveur MCP des agents. À part : l'exécutable n'a besoin
        // d'aucune section de l'interface.
        .executable(name: "oust", targets: ["OustCLI"]),
        .library(name: "OustAgentKit", type: .static, targets: ["OustAgent"]),
    ],
    targets: [

        // MARK: Domaine

        .target(name: "OustCore", swiftSettings: .strict),

        // MARK: Couches de soutien

        .target(
            name: "OustLocalization",
            resources: [.process("Resources")],
            swiftSettings: .strict
        ),
        .target(
            name: "OustDesignSystem",
            dependencies: ["OustCore", "OustLocalization"],
            swiftSettings: .strict
        ),

        // MARK: Moteurs

        .target(name: "OustScan", dependencies: ["OustCore"], swiftSettings: .strict),
        .target(name: "OustAPFS"),
        .target(name: "OustVolume", dependencies: ["OustCore", "OustHelperContract", "OustAPFS"], swiftSettings: .strict),
        .target(name: "OustUpdates", dependencies: ["OustCore", "OustHelperContract"], swiftSettings: .strict),
        .target(name: "OustSafety", dependencies: ["OustCore"], swiftSettings: .strict),
        .target(
            name: "OustRules",
            dependencies: ["OustCore", "OustScan", "OustSafety"],
            swiftSettings: .strict
        ),
        .target(
            name: "OustClean",
            dependencies: ["OustCore", "OustSafety", "OustVolume"],
            swiftSettings: .strict
        ),
        .target(
            name: "OustDuplicates",
            dependencies: ["OustCore", "OustScan"],
            swiftSettings: .strict
        ),
        .target(name: "OustBrowsers", dependencies: ["OustCore"], swiftSettings: .strict),

        // MARK: Moteurs de la phase 2

        .target(
            name: "OustUninstall",
            dependencies: ["OustCore", "OustScan", "OustSafety"],
            swiftSettings: .strict
        ),
        .target(
            name: "OustArchive",
            dependencies: ["OustCore", "OustScan", "OustSafety", "OustClean"],
            swiftSettings: .strict
        ),
        .target(
            name: "OustLargeFiles",
            dependencies: ["OustCore", "OustScan", "OustSafety"],
            swiftSettings: .strict
        ),
        .target(name: "OustSunburst", dependencies: ["OustScan"], swiftSettings: .strict),

        // MARK: Démon privilégié (docs/adr/0001)
        //
        // Le contrat, partagé avec l'application, et le service, que seul le
        // démon lie : le code qui tourne en root ne voit rien d'autre.

        .target(name: "OustHelperContract", swiftSettings: .strict),
        .target(name: "OustHelperDaemon", dependencies: ["OustHelperContract"], swiftSettings: .strict),

        // MARK: Veille (phase 3)

        .target(name: "OustWatch", dependencies: ["OustCore", "OustRules"], swiftSettings: .strict),

        // MARK: Photothèque

        .target(name: "OustPhotos", dependencies: ["OustCore"], swiftSettings: .strict),

        // MARK: Nuages

        .target(name: "OustClouds", dependencies: ["OustCore", "OustScan", "OustSafety"], swiftSettings: .strict),

        // MARK: État de l'application

        .target(
            name: "OustModel",
            dependencies: [
                "OustCore", "OustScan", "OustVolume", "OustSafety", "OustRules", "OustUpdates",
                "OustClean", "OustDuplicates", "OustBrowsers", "OustLocalization",
                "OustUninstall", "OustArchive", "OustLargeFiles", "OustWatch", "OustPhotos", "OustClouds",
            ],
            swiftSettings: .strict
        ),

        // MARK: Interface des agents

        .target(
            name: "OustAgent",
            dependencies: [
                "OustCore", "OustScan", "OustVolume", "OustSafety", "OustRules", "OustClean",
                "OustLocalization", "OustDesignSystem", "OustModel",
            ],
            swiftSettings: .strict
        ),
        .executableTarget(name: "OustCLI", dependencies: ["OustAgent"], swiftSettings: .strict),

        // MARK: Sections de l'interface

        .target(name: "FeatureOverview", dependencies: .feature + ["OustVolume"], swiftSettings: .strict),
        .target(name: "FeatureDevAI", dependencies: .feature, swiftSettings: .strict),
        .target(
            name: "FeatureExplorer",
            dependencies: .feature + ["OustScan", "OustSunburst"],
            swiftSettings: .strict
        ),
        .target(name: "FeatureArchive", dependencies: .feature + ["OustArchive"], swiftSettings: .strict),
        .target(
            name: "FeatureLargeFiles",
            dependencies: .feature + ["OustLargeFiles", "OustScan"],
            swiftSettings: .strict
        ),
        .target(name: "FeatureApplications", dependencies: .feature + ["OustUninstall"], swiftSettings: .strict),
        .target(name: "FeatureDuplicates", dependencies: .feature, swiftSettings: .strict),
        .target(name: "FeaturePhotos", dependencies: .feature + ["OustPhotos"], swiftSettings: .strict),
        .target(name: "FeatureClouds", dependencies: .feature + ["OustClouds", "OustScan"], swiftSettings: .strict),
        .target(name: "FeatureBrowsers", dependencies: .feature, swiftSettings: .strict),
        .target(name: "FeatureSystem", dependencies: .feature, swiftSettings: .strict),
        .target(name: "FeatureCart", dependencies: .feature, swiftSettings: .strict),
        .target(name: "FeatureHistory", dependencies: .feature, swiftSettings: .strict),
        .target(name: "FeatureSettings", dependencies: .feature + ["OustWatch"], swiftSettings: .strict),
        .target(name: "FeatureSearch", dependencies: .feature, swiftSettings: .strict),
        .target(name: "FeatureDisks", dependencies: .feature + ["OustScan", "OustVolume", "OustClean"], swiftSettings: .strict),
        .target(name: "FeatureMenuBar", dependencies: .feature + ["OustWatch"], swiftSettings: .strict),

        // MARK: Tests

        .testTarget(name: "OustCoreTests", dependencies: ["OustCore"]),
        .testTarget(name: "OustScanTests", dependencies: ["OustScan"]),
        .testTarget(name: "OustVolumeTests", dependencies: ["OustVolume"]),
        .testTarget(name: "OustSafetyTests", dependencies: ["OustSafety"]),
        .testTarget(name: "OustRulesTests", dependencies: ["OustRules", "OustLocalization"]),
        .testTarget(name: "OustCleanTests", dependencies: ["OustClean"]),
        .testTarget(name: "OustDuplicatesTests", dependencies: ["OustDuplicates"]),
        .testTarget(name: "OustBrowsersTests", dependencies: ["OustBrowsers", "OustCore", "OustSafety"]),
        .testTarget(
            name: "OustLocalizationTests",
            dependencies: ["OustLocalization", "OustCore", "OustUninstall", "OustArchive", "OustModel"]
        ),
        .testTarget(name: "OustUninstallTests", dependencies: ["OustUninstall", "OustClean", "OustCore", "OustSafety"]),
        .testTarget(name: "OustModelTests", dependencies: ["OustModel", "OustCore", "OustVolume"]),
        .testTarget(name: "OustUpdatesTests", dependencies: ["OustUpdates", "OustCore"]),
        .testTarget(name: "OustArchiveTests", dependencies: ["OustArchive", "OustClean", "OustCore", "OustSafety"]),
        .testTarget(name: "OustLargeFilesTests", dependencies: ["OustLargeFiles", "OustScan", "OustCore", "OustSafety"]),
        .testTarget(name: "OustSunburstTests", dependencies: ["OustSunburst", "OustScan"]),
        .testTarget(
            name: "OustHelperTests",
            dependencies: ["OustHelperContract", "OustHelperDaemon", "OustVolume", "OustCore"]
        ),
        .testTarget(
            name: "OustAgentTests",
            dependencies: ["OustAgent", "OustCore", "OustRules", "OustClean", "OustSafety", "OustModel"]
        ),
        .testTarget(name: "OustWatchTests", dependencies: ["OustWatch", "OustCore", "OustRules", "OustClean", "OustSafety"]),
        .testTarget(name: "OustPhotosTests", dependencies: ["OustPhotos", "OustCore"]),
        .testTarget(name: "OustCloudsTests", dependencies: ["OustClouds", "OustScan", "OustCore", "OustSafety", "OustClean"]),
    ]
)

extension Array where Element == Target.Dependency {
    /// Ce qu'une section de l'interface a le droit de connaître.
    static var feature: [Target.Dependency] {
        ["OustCore", "OustModel", "OustDesignSystem", "OustLocalization"]
    }
}

extension Array where Element == SwiftSetting {
    /// Appliqué à chaque cible livrée.
    static var strict: [SwiftSetting] {
        [
            .enableUpcomingFeature("ExistentialAny"),
        ]
    }
}
