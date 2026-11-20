import Testing
import Darwin
import Foundation
import OustCore
import OustRules
import OustSafety
import OustScan
@testable import OustModel

private final class DiskIdentityDefaults: UserDefaults, @unchecked Sendable {
 override func object(forKey key:String)->Any?{nil}
 override func data(forKey key:String)->Data?{nil}
 override func stringArray(forKey key:String)->[String]?{nil}
 override func bool(forKey key:String)->Bool{false}
 override func set(_ value:Any?,forKey key:String){}
}
private actor IdentityGate {
 var entered=false
 var waiter:CheckedContinuation<Void,Never>?
 var release:CheckedContinuation<Void,Never>?
 func wait() async {
  entered=true; waiter?.resume();waiter=nil
  await withCheckedContinuation{release=$0}
 }
 func untilEntered() async {if entered{return};await withCheckedContinuation{waiter=$0}}
 func finish(){release?.resume();release=nil}
}
@MainActor private struct IdentityFixture {
 let root:URL;let home:URL;let boot:VolumeDescriptor;let model:AppModel
 init() throws {
  let made=FileManager.default.temporaryDirectory.appendingPathComponent("oust-ultra-frame-\(UUID())")
  try FileManager.default.createDirectory(at:made,withIntermediateDirectories:true)
  root=made.resolvingSymlinksInPath();home=root.appendingPathComponent("boot")
  try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
  try Data([1,2,3]).write(to:home.appendingPathComponent("fiction.bin"))
  var v=VolumeDescriptor(name:"Fictif",mountURL:home,scanRoot:home,isBoot:true,isInternal:true,isRemovable:false,capacity:Capacity(total:1000,available:100,availableForImportantUsage:100))
  v.mountIdentity=try Self.identity(home);boot=v
  model=AppModel(home:home,defaults:DiskIdentityDefaults(),disk:DiskIndexModel(store:TreeStore(directory:root.appendingPathComponent("Index"))))
  model.volumes=[v];model.watch.updateBoot(v)
 }
 static func identity(_ url:URL)throws->VolumeMountIdentity {
  var st=stat();var fs=statfs()
  guard lstat(url.path,&st)==0,statfs(url.path,&fs)==0 else{throw NSError(domain:"fixture",code:1)}
  return VolumeMountIdentity(device:st.st_dev,inode:UInt64(st.st_ino),createdSeconds:st.st_birthtimespec.tv_sec,createdNanoseconds:st.st_birthtimespec.tv_nsec,filesystemID:[fs.f_fsid.val.0,fs.f_fsid.val.1])
 }
 func collect(_ request:BootAnalysisRequest)async {
  let context=RuleContext(home:home,projectRoots:[],processes:ProcessSnapshot(processes:[]),applications:root,systemLibrary:root,sharedFolder:root,temporaryDirectory:root,runningApps:[])
  await model.runBootAnalysis(request,context:context,finders:[])
 }
 func intact()->Bool{(try? Data(contentsOf:home.appendingPathComponent("fiction.bin")))==Data([1,2,3])}
 func remove(){try? FileManager.default.removeItem(at:root)}
}
@Suite("Identité de collecte et ordre des lectures") @MainActor
struct DiskIdentityCorrectionsTests {
 @Test("Le moniteur et la lecture directe invalident la preuve au point commun", arguments:["direct", "monitor", "preview"])
 func allReadEntrypoints(_ entry:String) async throws {
  let f=try IdentityFixture();defer{f.remove()}
  f.model.recordVolumeAnalysis(for:f.boot)
  f.model.startGuidedReviewFromSidebar()
  let old=try #require(f.model.guidedReview)
  if entry == "direct" {await f.model.watch.refreshDisk(read:{nil})}
  else if entry == "preview" {f.model.watch.showAlertPreview(read:{nil})}
  else {f.model.watch.updateBoot(nil)}
  #expect(f.model.startupReadUnverified && f.model.guidedReview==nil)
  #expect(f.model.completedVolumeAnalyses[f.boot.id]==nil)
  f.model.resumeGuidedReview(token:old.token)
  f.model.startGuidedReviewFromSidebar()
  #expect(f.model.guidedReview==nil && f.model.reserveBootAnalysis(f.boot,preselect:false)==nil)
  f.model.publishReclaimedCapacity(Capacity(total:1000,available:700,availableForImportantUsage:700))
  #expect(f.model.watch.boot==nil && f.model.startupReadUnverified)
  #expect(f.intact() && f.model.cart.isEmpty && !f.model.canMoveFiles)
 }
 @Test("Une capacité récente ne masque pas une lecture d’identité plus ancienne", arguments:[true,false])
 func capacityDoesNotQualify(_ identitySucceeds:Bool) async throws {
  let f=try IdentityFixture();defer{f.remove()}
  f.model.recordVolumeAnalysis(for:f.boot)
  f.model.startGuidedReviewFromSidebar()
  let gate=IdentityGate()
  let pending=Task{@MainActor in await f.model.refreshStartupVolume(read:{await gate.wait();return identitySucceeds ? f.boot:nil})}
  await gate.untilEntered()
  f.model.publishReclaimedCapacity(Capacity(total:1000,available:700,availableForImportantUsage:700))
  await gate.finish();await pending.value
  #expect((f.model.guidedReview != nil)==identitySucceeds)
  #expect(f.model.startupReadUnverified == !identitySucceeds)
  #expect((f.model.completedVolumeAnalyses[f.boot.id] != nil)==identitySucceeds)
  if identitySucceeds {#expect(f.model.watch.boot?.capacity.available==700 && f.model.volumes.first?.capacity.available==700)}
  #expect(f.intact() && f.model.cart.isEmpty && !f.model.canMoveFiles)
 }
 @Test("Une capacité de l’ancienne qualification ne revient pas après un échec")
 func oldCapacityAfterRequalification() async throws {
  let f=try IdentityFixture();defer{f.remove()}
  let epoch=f.model.startupQualificationRevision
  await f.model.watch.refreshDisk(read:{nil})
  await f.model.watch.refreshDisk(read:{f.boot})
  f.model.publishReclaimedCapacity(Capacity(total:1000,available:700,availableForImportantUsage:700),for:f.boot,qualificationRevision:epoch)
  #expect(f.model.watch.boot?.capacity.available==100 && f.model.volumes.first?.capacity.available==100)
  #expect(f.intact() && f.model.cart.isEmpty && !f.model.canMoveFiles)
 }
 @Test("La capacité reste liée au volume capturé, même après remplacement au même chemin")
 func capacityWrongTarget() async throws {
  let f=try IdentityFixture();defer{f.remove()}
  let epoch=f.model.startupQualificationRevision
  try FileManager.default.moveItem(at:f.home,to:f.root.appendingPathComponent("kept"))
  try FileManager.default.createDirectory(at:f.home,withIntermediateDirectories:true)
  try Data([1,2,3]).write(to:f.home.appendingPathComponent("fiction.bin"))
  var next=f.boot;next.mountIdentity=try IdentityFixture.identity(f.home)
  let fresh=next
  await f.model.watch.refreshDisk(read:{fresh})
  f.model.publishReclaimedCapacity(Capacity(total:1000,available:700,availableForImportantUsage:700),for:f.boot,qualificationRevision:epoch)
  #expect(f.model.watch.boot?.mountIdentity==next.mountIdentity && f.model.watch.boot?.capacity.available==100)
  #expect(f.intact() && f.model.cart.isEmpty && !f.model.canMoveFiles)
 }
 @Test("Le remplacement avant la première Location ne publie aucune preuve")
 func replacementBeforeLocation() async throws {
  let f=try IdentityFixture();defer{f.remove()}
  let request=try #require(f.model.reserveBootAnalysis(f.boot,preselect:false))
  let kept=f.root.appendingPathComponent("kept")
  try FileManager.default.moveItem(at:f.home,to:kept)
  try FileManager.default.createDirectory(at:f.home,withIntermediateDirectories:true)
  try Data([7,8]).write(to:f.home.appendingPathComponent("fiction.bin"))
  await f.collect(request)
  #expect(f.model.completedVolumeAnalyses[f.boot.id]==nil)
  #expect(!f.model.canStartGuidedReviewFromSidebar && f.model.cart.isEmpty && !f.model.canMoveFiles)
  #expect(try Data(contentsOf:kept.appendingPathComponent("fiction.bin"))==Data([1,2,3]))
  #expect(try Data(contentsOf:f.home.appendingPathComponent("fiction.bin"))==Data([7,8]))
 }
 @Test("Après un échec, une lecture réussie est nécessaire avant la collecte")
 func failedReadRequiresQualification() async throws {
  let f=try IdentityFixture();defer{f.remove()}
  f.model.recordVolumeAnalysis(for:f.boot)
  await f.model.refreshStartupVolume(read:{nil})
  #expect(f.model.reserveBootAnalysis(f.boot,preselect:false)==nil)
  #expect(!f.model.canStartGuidedReviewFromSidebar)
  await f.model.refreshStartupVolume(read:{f.boot})
  let request=try #require(f.model.reserveBootAnalysis(f.boot,preselect:false))
  await f.collect(request)
  #expect(f.model.canStartGuidedReviewFromSidebar && f.model.cart.isEmpty && !f.model.canMoveFiles)
  #expect(f.intact())
 }
 @Test("Une ancienne lecture ne contredit pas la plus récente, succès ou échec", arguments:[true,false])
 func orderedReads(_ latestSucceeds:Bool) async throws {
  let f=try IdentityFixture();defer{f.remove()}
  let gate=IdentityGate()
  let old=Task{@MainActor in await f.model.refreshStartupVolume(read:{await gate.wait();return latestSucceeds ? nil:f.boot})}
  await gate.untilEntered()
  var newer=f.boot;newer.capacity=Capacity(total:1000,available:700,availableForImportantUsage:700)
  let newest=newer
  await f.model.refreshStartupVolume(read:{latestSucceeds ? newest:nil})
  if latestSucceeds {
   let request=try #require(f.model.reserveBootAnalysis(newest,preselect:false))
   await f.collect(request)
   f.model.startGuidedReviewFromSidebar()
   #expect(f.model.guidedReview != nil)
  }
  await gate.finish();await old.value
  #expect((f.model.completedVolumeAnalyses[f.boot.id] != nil)==latestSucceeds)
  #expect((f.model.guidedReview != nil)==latestSucceeds)
  if latestSucceeds {#expect(f.model.bootVolume?.capacity.available==700)}
  else {#expect(f.model.reserveBootAnalysis(f.boot,preselect:false)==nil)}
  #expect(f.intact() && f.model.cart.isEmpty && !f.model.canMoveFiles)
 }
 @Test("Une collecte réservée avant l’échec ne revient pas après requalification")
 func oldRequestAfterFailure() async throws {
  let f=try IdentityFixture();defer{f.remove()}
  let request=try #require(f.model.reserveBootAnalysis(f.boot,preselect:false))
  await f.model.refreshStartupVolume(read:{nil})
  await f.model.refreshStartupVolume(read:{f.boot})
  await f.collect(request)
  #expect(f.model.completedVolumeAnalyses[f.boot.id]==nil && !f.model.canStartGuidedReviewFromSidebar)
  #expect(f.intact() && f.model.cart.isEmpty && !f.model.canMoveFiles)
 }
}
