import Foundation
import CryptoKit
import OustHelperContract
import Security
import ServiceManagement
import Synchronization

/// Le démon privilégié, côté application (docs/adr/0001).
///
/// Optionnel de bout en bout. Tant qu'il n'est pas installé et approuvé, ou
/// s'il ne répond pas, ou s'il refuse la demande entière, rien n'a été fait et
/// `VolumeService` reprend l'invite administrateur d'avant. Quand il répond,
/// il dit ce qu'il a fait date par date, et c'est cette réponse qui compte :
/// on ne redemande pas en administrateur ce que le démon a déjà tenté.
public enum PrivilegedHelper {

    // MARK: Installation

    public enum Registration: Sendable, Equatable {
        case notInstalled
        /// Enregistré, mais pas encore activé dans Réglages Système › Ouverture.
        case awaitingApproval
        case enabled
    }

    static var service: SMAppService { SMAppService.daemon(plistName: HelperContract.daemonPlistName) }

    public static var registration: Registration {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .awaitingApproval
        // `.notFound` : une copie dont le paquet ne contient pas le démon, ou
        // le processus de test. Dans les deux cas, il n'est pas là.
        default: .notInstalled
        }
    }

    /// Enregistre le démon. macOS demande ensuite de l'activer dans Réglages
    /// Système › Ouverture, avec le mot de passe d'un administrateur : c'est
    /// incontournable, et les Réglages d'Oust! le disent avant.
    public static func install() throws {
        guard beginMaintenance() else { throw LifecycleError.busy }
        defer { endMaintenance() }
        try service.register()
        rememberFingerprint()
    }

    /// Diagnostic de la copie courante, sans enregistrer ni lancer le démon.
    /// Un enregistrement réussi n'atteste pas que launchd sait encore retrouver
    /// le programme après un déplacement ou un remplacement de l'app.
    public enum InstallationIssue: String, Sendable, Equatable {
        case incompleteBundle = "helper.diagnostic.incomplete_bundle"
        case invalidConfiguration = "helper.diagnostic.invalid_configuration"
        case invalidSignature = "helper.diagnostic.invalid_signature"
    }

    public static var installationIssue: InstallationIssue? {
        inspectBundle(at: Bundle.main.bundleURL)
    }

    public static var isInApplications: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications"
    }

    static func inspectBundle(at bundleURL: URL) -> InstallationIssue? {
        let executable = bundleURL.appendingPathComponent("Contents/MacOS/oust-helper")
        let plistURL = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + HelperContract.daemonPlistName)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: plistURL) else { return .incompleteBundle }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == HelperContract.daemonIdentifier,
              plist["BundleProgram"] as? String == "Contents/MacOS/oust-helper",
              (plist["MachServices"] as? [String: Any])?[HelperContract.machServiceName] as? Bool == true,
              plist["Program"] == nil, plist["ProgramArguments"] == nil else { return .invalidConfiguration }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(HelperContract.daemonRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            return .invalidSignature
        }
        return nil
    }

    /// Le retire. Un démon en cours d'exécution est arrêté par le système.
    public static func uninstall() async throws {
        guard beginMaintenance() else { throw LifecycleError.busy }
        defer { endMaintenance() }
        try await service.unregister()
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
    }

    /// Le retrait asynchrone attend l'arrêt du processus avant l'enregistrement.
    public static func reinstall() async throws {
        guard beginMaintenance() else { throw LifecycleError.busy }
        defer { endMaintenance() }
        try await service.unregister()
        try service.register()
        rememberFingerprint()
    }

    public enum LifecycleError: Error { case busy }

    public enum UpdateState: Sendable, Equatable {
        case none
        case deferred
    }

    private struct Lifecycle {
        var mutations = 0
        var maintenance = false
        var startupAttempted = false
        var update: UpdateState = .none
    }
    private static let lifecycle = Mutex(Lifecycle())
    private static let fingerprintKey = "privilegedHelper.registeredFingerprint"
    public static var updateState: UpdateState { lifecycle.withLock { $0.update } }

    private static func beginMaintenance() -> Bool {
        lifecycle.withLock {
            guard !$0.maintenance, $0.mutations == 0 else { return false }
            $0.maintenance = true
            return true
        }
    }
    private static func endMaintenance() { lifecycle.withLock { $0.maintenance = false } }
    private static func beginMutation() -> Bool {
        lifecycle.withLock {
            guard !$0.maintenance else { return false }
            $0.mutations += 1
            return true
        }
    }
    private static func endMutation() { lifecycle.withLock { $0.mutations -= 1 } }

    private static func fingerprint() -> String? {
        let bundleURL = Bundle.main.bundleURL
        guard let executable = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/MacOS/oust-helper")),
              let plist = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + HelperContract.daemonPlistName)) else { return nil }
        var hash = SHA256()
        hash.update(data: Data(bundleURL.standardizedFileURL.path.utf8))
        hash.update(data: executable)
        hash.update(data: plist)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func rememberFingerprint() {
        // Un refus d'approbation n'est jamais mémorisé comme une installation
        // fonctionnelle, et une empreinte ne vaut jamais autorisation macOS.
        if registration == .enabled, let fingerprint = fingerprint() {
            UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
            lifecycle.withLock { $0.update = .none }
        }
    }

    /// Actualise uniquement le diagnostic, sans modifier l'enregistrement.
    /// Un PID absent ou une sonde de version ne ferment pas la course avec une
    /// autre copie d'Oust! qui lancerait une suppression avant `unregister`.
    /// Toute réparation reste donc explicitement demandée par l'utilisateur.
    public static func synchronizeApprovedInstallation() async {
        let shouldAttempt = lifecycle.withLock {
            guard !$0.startupAttempted else { return false }
            $0.startupAttempted = true
            return true
        }
        guard shouldAttempt, installationIssue == nil else { return }
        let update = installationUpdate(registration: registration, currentFingerprint: fingerprint(),
                                       registeredFingerprint: UserDefaults.standard.string(forKey: fingerprintKey))
        lifecycle.withLock { $0.update = update }
    }

    static func installationUpdate(registration: Registration, currentFingerprint: String?,
                                   registeredFingerprint: String?) -> UpdateState {
        guard registration == .enabled, let currentFingerprint,
              currentFingerprint != registeredFingerprint else { return .none }
        return .deferred
    }

    /// Le volet exact des Réglages Système, plutôt que de laisser chercher.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// L'app est-elle signée « Developer ID Application » ?
    ///
    /// macOS exige d'une app qui embarque un démon qu'elle soit notarisée
    /// (en-tête de `SMAppService`) ; Tacho a vu une copie de développement
    /// refusée avec « Codesigning failure loading plist ». On le dit avant
    /// d'essayer, sans l'interdire : l'essai ne coûte rien et ne demande rien.
    public static let isDeveloperIDSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
                "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]" as CFString,
                [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }()

    // MARK: Verbes

    /// L'issue d'un appel au démon.
    enum Call<Value: Sendable>: Sendable {
        case answered(Value)
        /// Pas installé, pas approuvé, injoignable, ou l'une des deux
        /// signatures refusée : rien n'a été demandé au démon, ou il n'a rien
        /// pu en faire.
        case unreachable
        /// Parti, mais sans réponse à temps : le démon travaille peut-être
        /// encore. Ni succès, ni raison de recommencer par un autre chemin.
        case timedOut
    }

    /// Comment joindre le démon. Les tests le remplacent par un écouteur
    /// anonyme dans leur propre processus.
    struct Transport: Sendable {
        var isRegistered: @Sendable () -> Bool
        var connect: @Sendable () -> NSXPCConnection
        var daemonRequirement: String

        static let system = Transport(
            isRegistered: { registration == .enabled },
            connect: { NSXPCConnection(machServiceName: HelperContract.machServiceName, options: .privileged) },
            daemonRequirement: HelperContract.daemonRequirement
        )
    }

    /// Demande la suppression de ces snapshots. N'est appelé que par
    /// `VolumeService.deleteSnapshots`, lui-même appelé par `CleanupEngine` :
    /// rien n'est supprimé sans passer par OustClean (RULES.md, règle 1).
    ///
    /// Une demande refusée en bloc (contrat d'une autre version, liste
    /// illisible…) n'a rien fait : elle compte comme injoignable, et l'invite
    /// administrateur prend le relais.
    static func deleteSnapshots(dates: [String], transport: Transport = .system,
                                timeout: TimeInterval = 300,
                                deletionStarted: @Sendable () -> Void = {},
                                isCancelled: @Sendable () -> Bool = { false }) async -> Call<DeletionResponse> {
        guard beginMutation() else { return .unreachable }
        defer { endMutation() }
        // Un service peut être « activé » mais ne jamais démarrer (EX_CONFIG
        // observé le 20/10/2026). Ne pas lui confier une mutation avec le long
        // délai APFS avant d'avoir reçu une réponse de lecture en cinq secondes.
        // Aucun ordre de suppression n'a encore été envoyé : le repli est sûr.
        guard await status(transport: transport, timeout: min(5, timeout)) != nil else { return .unreachable }
        guard !isCancelled() else { return .unreachable }
        deletionStarted()
        let call: Call<DeletionResponse?> = await send(transport: transport, timeout: timeout) { proxy, finish in
            proxy.deleteLocalSnapshots(dates, contractVersion: HelperContract.version) { reply in
                finish(DeletionResponse(dictionary: reply))
            }
        }
        switch call {
        case .answered(let response?) where response.refusal == nil: return .answered(response)
        case .answered: return .unreachable
        case .unreachable: return .unreachable
        case .timedOut: return .timedOut
        }
    }

    /// Demande la suppression de ces sauvegardes Time Machine. N'est appelé que
    /// par `TimeMachineService.deleteBackups`, lui-même appelé par
    /// `BackupPruner` (OustClean, règle 1).
    ///
    /// La version du démon est lue d'abord : un démon de la version 1 ne
    /// connaît pas ce verbe, et le lui envoyer ne ferait qu'attendre le délai.
    /// Un refus en bloc est rendu tel quel : c'est à l'appelant de dire lequel
    /// laisse la main à l'invite (une liste illisible) et lequel arrête tout
    /// (une sauvegarde en cours). Une réponse illisible compte comme
    /// injoignable, et l'invite prend le relais : ce qui est vraiment parti ne
    /// se lit de toute façon que dans la liste relue par `BackupPruner`.
    static func deleteBackups(_ timestamps: [String], destination: String, transport: Transport = .system,
                              timeout: TimeInterval) async -> Call<BackupDeletionResponse> {
        guard beginMutation() else { return .unreachable }
        defer { endMutation() }
        guard await status(transport: transport) != nil else { return .unreachable }
        let call: Call<BackupDeletionResponse?> = await send(transport: transport, timeout: timeout) { proxy, finish in
            proxy.deleteBackups(timestamps, destination: destination, contractVersion: HelperContract.version) { reply in
                finish(BackupDeletionResponse(dictionary: reply))
            }
        }
        switch call {
        case .answered(let response?): return .answered(response)
        case .answered, .unreachable: return .unreachable
        case .timedOut: return .timedOut
        }
    }

    /// La version du démon, s'il répond.
    public static func status() async -> HelperStatus? {
        await status(transport: .system)
    }

    static func status(transport: Transport, timeout: TimeInterval = 5) async -> HelperStatus? {
        let call: Call<HelperStatus?> = await send(transport: transport, timeout: timeout) { proxy, finish in
            proxy.readStatus { reply in finish(HelperStatus(dictionary: reply)) }
        }
        if case .answered(let status?) = call, status.contractVersion == HelperContract.version { return status }
        return nil
    }

    /// Une connexion par appel, fermée aussitôt après : les appels sont rares,
    /// et une connexion gardée ouverte serait un état de plus à surveiller.
    private static func send<Value: Sendable>(
        transport: Transport, timeout: TimeInterval,
        _ body: (any OustHelperProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Call<Value> {
        guard transport.isRegistered() else { return .unreachable }
        let connection = transport.connect()
        connection.remoteObjectInterface = HelperInterface.make()
        // Symétrique de la vérification du démon : l'application ne parle
        // qu'à un binaire de l'équipe, sous l'identifiant attendu.
        connection.setCodeSigningRequirement(transport.daemonRequirement)
        let once = Once<Call<Value>>()
        connection.invalidationHandler = { once.resume(.unreachable) }
        connection.interruptionHandler = { once.resume(.unreachable) }
        connection.resume()
        defer { connection.invalidate() }

        return await withCheckedContinuation { continuation in
            once.attach(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(.unreachable) }
            guard let helper = proxy as? any OustHelperProtocol else {
                once.resume(.unreachable)
                return
            }
            body(helper) { once.resume(.answered($0)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.timedOut) }
        }
    }

    /// Reprend la continuation une seule fois, quelle que soit la première
    /// nouvelle : réponse, erreur, invalidation ou délai.
    private final class Once<Value: Sendable>: Sendable {
        private let state = Mutex<(continuation: CheckedContinuation<Value, Never>?, early: Value?, done: Bool)>(
            (nil, nil, false))

        func attach(_ continuation: CheckedContinuation<Value, Never>) {
            let early: Value? = state.withLock { state in
                if let early = state.early { state.early = nil; return early }
                state.continuation = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func resume(_ value: Value) {
            let continuation: CheckedContinuation<Value, Never>? = state.withLock { state in
                guard !state.done else { return nil }
                state.done = true
                guard let continuation = state.continuation else {
                    state.early = value
                    return nil
                }
                state.continuation = nil
                return continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
