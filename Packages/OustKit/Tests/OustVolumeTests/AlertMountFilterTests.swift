import Testing
import OustCore
@testable import OustVolume
@Suite struct AlertMountFilterTests {
    @Test func networkRejectedBeforeMetadata() {
        let smb = MountedFileSystems.Entry(path: "/Volumes/FictionalSMB", type: "smbfs", source: "fiction", identity: [1,2], isLocal: false, isHidden: false)
        let local = MountedFileSystems.Entry(path: "/Volumes/FictionalUSB", type: "apfs", source: "fiction", identity: [3,4], isLocal: true, isHidden: false)
        #expect(VolumeService.alertCandidates([smb, local]) == [local])
    }
}
