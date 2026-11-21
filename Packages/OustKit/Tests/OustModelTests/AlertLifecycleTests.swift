import Foundation
import Testing
import OustWatch
@testable import OustModel

private actor LifecycleGate {
    var entered = false; var open = false
    var waiter: CheckedContinuation<Void, Never>?; var ready: CheckedContinuation<Void, Never>?
    func wait() async { if open { return }; entered = true; ready?.resume(); ready = nil; await withCheckedContinuation { waiter = $0 } }
    func untilEntered() async { if !entered { await withCheckedContinuation { ready = $0 } } }
    func finish() { open = true; waiter?.resume(); waiter = nil }
}
@Suite @MainActor struct AlertLifecycleTests {
    @Test func channelDisabledWhileReadIsSuspended() async {
        let gate = LifecycleGate()
        var enabled = true, sent = 0, reserved = false
        let pending = Task { await AlertNotificationGate.send(permission: { true }, enabled: { enabled }, current: { await gate.wait(); return 1 },
            reserve: { _ in reserved = true; return true }, post: { _ in sent += 1; return true }, complete: { _ in }, withdraw: {}) }
        await gate.untilEntered(); enabled = false; await gate.finish(); await pending.value
        #expect(sent == 0 && !reserved)
    }
    @Test func acceptedEventSurvivesPartialExpirationOrBusyRead() async {
        let gate = LifecycleGate()
        var valid = true, removed = false, accepted = false
        let pending = Task { await AlertNotificationGate.send(permission: { true }, enabled: { true }, current: { valid ? 1 : nil },
            reserve: { _ in true }, post: { _ in await gate.wait(); return true }, complete: { accepted = $0 }, withdraw: { removed = true }) }
        await gate.untilEntered(); valid = false; await gate.finish(); await pending.value
        #expect(accepted && !removed)
    }
    @Test(arguments: [true, false]) func realCoordinatorRetriesFailedSourceAndCharge(_ charged: Bool) async throws {
        let defaults = MemoryDefaults()
        let settings = WatchSettings(batteryAlerts: BatteryAlertSettings(warnsCharged: true, warnsConnected: true, notifies: true))
        defaults.set(settings.encoded(), forKey: "watch.settings")
        let reading = BatteryReading(level: charged ? 80 : 50, state: .charging)
        var posts = 0
        let watch = WatchModel(defaults: defaults, powerRead: { reading }, powerPermission: { true }, powerPost: { _,_,_,_,_,_ in posts += 1; return posts > 1 })
        let original = PowerAlertComponent(id: "fictional-occurrence", alert: charged ? .charged(reading) : .connected(reading))
        watch.deliverPowerComponents([original], cycle: watch.batteryAlertCycle)
        await watch.waitForAlertDelivery()
        #expect(posts == 1)
        // Changement externe réel de réglage : retryFailures puis reprise du coordinateur.
        watch.settings.playsAlertSounds.toggle()
        await watch.waitForAlertDelivery()
        #expect(posts == 2)
        watch.settings.playsAlertSounds.toggle()
        await watch.waitForAlertDelivery()
        #expect(posts == 2)
    }
    @Test func failedIntentsPersistExpireAndRejectBackwardClock() throws {
        let wall = Date(timeIntervalSince1970: 1000), occurrence = UUID()
        let now = ContinuousClock.now, deadline = now.advanced(by: .seconds(15))
        var bank = FailedPowerIntents()
        bank.record(id: "a", components: [PowerAlertComponent(id: "occurrence", alert: .connected(.init(level: 50, state: .charging)))], observedAt: wall,
                    occurrence: occurrence, deadline: deadline)
        let pending = bank.pending(now: now.advanced(by: .seconds(3)), occurrence: occurrence)
        #expect(pending.first?.components.first?.id == "occurrence")
        var restored = try JSONDecoder().decode(FailedPowerIntents.self, from: JSONEncoder().encode(bank))
        let unproven = restored.pending(now: now, occurrence: occurrence)
        #expect(unproven.isEmpty)
        let expired = bank.pending(now: now.advanced(by: .seconds(16)), occurrence: occurrence)
        #expect(expired.isEmpty)
    }
}
