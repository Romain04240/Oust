import Foundation
import Observation
import OustCore
import OustVolume

/// Une seule mesure APFS affichable, liée au disque demandé plutôt qu’à la
/// durée de vie de la feuille SwiftUI qui présente ses détails.
@MainActor
@Observable
public final class StorageDetailsModel {
    public struct Identity: Hashable, Sendable {
        private let volumeID: String
        private let scanRoot: URL
        private let mountIdentity: VolumeMountIdentity?

        fileprivate init(_ volume: VolumeDescriptor) {
            volumeID = volume.id
            scanRoot = volume.scanRoot
            mountIdentity = volume.mountIdentity
        }
    }

    private var target: Identity?
    private var value: APFSContainerUsage?
    private var loading = false
    @ObservationIgnored private var requestToken: UUID?
    @ObservationIgnored private let read: @Sendable (URL) async -> APFSContainerUsage?

    public convenience init() {
        self.init(read: { await APFSContainerUsage.read(for: $0) })
    }

    init(read: @escaping @Sendable (URL) async -> APFSContainerUsage?) {
        self.read = read
    }

    public func identity(for volume: VolumeDescriptor) -> Identity { Identity(volume) }

    public func isLoading(for volume: VolumeDescriptor) -> Bool {
        target != identity(for: volume) || loading
    }

    public func usage(for volume: VolumeDescriptor) -> APFSContainerUsage? {
        target == identity(for: volume) ? value : nil
    }

    public func load(for volume: VolumeDescriptor) async {
        guard !Task.isCancelled else { return }
        let identity = identity(for: volume)
        let token = UUID()
        requestToken = token
        target = identity
        value = nil
        loading = true
        defer {
            // Une ancienne lecture ne retire jamais le chargement de sa relève.
            if requestToken == token { loading = false }
        }
        let usage = await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(true) {
            await read(volume.scanRoot)
        }
        guard !Task.isCancelled, requestToken == token, target == identity else { return }
        value = usage
    }
}
