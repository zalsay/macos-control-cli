import Foundation
import Darwin
import CryptoKit
import BinderIdentity

/// This reader never follows the final path and never reads more than limit bytes.
/// Cross-file atomicity and hostile same-UID mutation are outside the fixture contract.
enum BoundedFixtureRead {
 static func read(_ path: String, limit: Int) throws -> Data {
  let fd = open(path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard fd >= 0 else { throw RepositoryBindingProvider.Failure.unsafeRepository }
  defer { close(fd) }
  var st = stat()
  guard fstat(fd,&st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
        (st.st_mode & 0o7777) == 0o600, st.st_uid == geteuid(), st.st_nlink == 1,
        st.st_size >= 0 else { throw RepositoryBindingProvider.Failure.unsafeRepository }
  guard st.st_size <= limit else { throw RepositoryBindingProvider.Failure.repositoryTooLarge }
  var result = Data(), buffer = [UInt8](repeating:0,count:16384)
  while result.count < limit {
   let n = Darwin.read(fd,&buffer,min(buffer.count,limit-result.count))
   if n < 0 && errno == EINTR { continue }
   guard n >= 0 else { throw RepositoryBindingProvider.Failure.unsafeRepository }
   if n == 0 { break }
   result.append(contentsOf:buffer.prefix(n))
  }
  var after = stat()
  guard fstat(fd,&after) == 0, after.st_dev == st.st_dev, after.st_ino == st.st_ino,
        after.st_size == st.st_size, st.st_size == result.count else {
   throw RepositoryBindingProvider.Failure.repositoryChanged
  }
  return result
 }
}

struct RepositoryFileObservation: Equatable {
 fileprivate var snapshot: BIFileSnapshot
 let rawSHA256: [UInt8]
 var size: UInt64 { snapshot.size }
 var device: UInt64 { snapshot.dev }
 var inode: UInt64 { snapshot.ino }
 var linkCount: UInt64 { snapshot.nlink }
 var uid: UInt32 { snapshot.uid }
 var gid: UInt32 { snapshot.gid }
 var mode: UInt32 { snapshot.mode }
 var mtimeSeconds: Int64 { snapshot.mtime_sec }
 var mtimeNanoseconds: Int64 { snapshot.mtime_nsec }
 var ctimeSeconds: Int64 { snapshot.ctime_sec }
 var ctimeNanoseconds: Int64 { snapshot.ctime_nsec }
 static func == (a:Self,b:Self) -> Bool {
  var x = a.snapshot, y = b.snapshot
  return bi_fixture_file_equal(&x,&y) != 0 && a.rawSHA256 == b.rawSHA256
 }
}
struct RepositoryObservation: Equatable {
 let file: RepositoryFileObservation
 let rawBytes: Data
 let records: [Profile]
 let profile: Profile
 let spec: RunnerLaunchSpec
 let dependencies: [String: RepositoryFileObservation]
 let proxy: ProxySettings?
 let subscription: Subscription?
 let node: SubscriptionNode?
}

actor RepositoryBindingProvider {
 enum Role { case controller, runner }
 enum Failure: Error, Equatable {
  case invalidExecutablePath, invalidArguments, directoryChanged, unsafeLock, lockUnavailable, lockLost
  case unsafeRepository, repositoryTooLarge, snapshotFailed, repositoryChanged, decodingFailed, duplicateID, missingProfile, profileDenied, deadline, closed
 }
 private static let maxBytes = 1_048_576
 private let rootPin: PrivateDirectoryPin, locksPin: PrivateDirectoryPin
 private let repoPath: String
 private let expectedSpec: RunnerLaunchSpec
 nonisolated let lock: ProfileLock.Lease?
 private let role: Role
 private var baseline: RepositoryObservation?
 private var closed = false

 private init(rootPin: PrivateDirectoryPin, locksPin: PrivateDirectoryPin, repoPath: String, expectedSpec: RunnerLaunchSpec, lock: ProfileLock.Lease?, role: Role) {
  self.rootPin = rootPin; self.locksPin = locksPin; self.repoPath = repoPath
  self.expectedSpec = expectedSpec; self.lock = lock; self.role = role
 }
 static func create(workspace: SafarierWorkspace, role: Role, expectedSpec: RunnerLaunchSpec, actualArgs: [String], environment: [String:String], originalLock: ProfileLock?) throws -> RepositoryBindingProvider {
  guard let parsed = try? RunnerLaunchSpec.parse(actualArgs,environment:environment), parsed == expectedSpec else { throw Failure.invalidArguments }
  let root = workspace.root.standardizedFileURL, locks = workspace.locksDirectory.standardizedFileURL
  let rp: PrivateDirectoryPin, lp: PrivateDirectoryPin
  do { rp = try PrivateDirectoryPin(path: root); lp = try PrivateDirectoryPin(path: locks) }
  catch { throw Failure.directoryChanged }
  guard rp.matches(), lp.matches() else { throw Failure.directoryChanged }
  var loan: ProfileLock.Lease?
  if role == .runner {
   guard let originalLock else { throw Failure.lockUnavailable }
   do { loan = try originalLock.borrow(profileID: expectedSpec.profileID, directory: locks) }
   catch { throw Failure.lockUnavailable }
   guard loan?.check() == true, rp.matches(), lp.matches() else { loan?.finish(); throw Failure.unsafeLock }
  } else if originalLock != nil { throw Failure.unsafeLock }
  return RepositoryBindingProvider(rootPin: rp, locksPin: lp, repoPath: root.appendingPathComponent("profiles.json").path, expectedSpec: expectedSpec, lock: loan, role: role)
 }
 private func checkPins() throws {
  guard rootPin.matches(), locksPin.matches() else { throw Failure.directoryChanged }
  if role == .runner { guard lock?.check() == true else { throw Failure.lockLost } }
 }
 private func checkDeadline(_ deadline: UInt64) throws {
  guard bi_fixture_deadline_valid(deadline) != 0 else { throw Failure.deadline }
 }
 private func snapshot(path: String, deadline: UInt64) throws -> RepositoryFileObservation {
  try checkDeadline(deadline)
  var st = stat()
  guard lstat(path,&st) == 0, (st.st_mode & S_IFMT) == S_IFREG, (st.st_mode & 0o7777) == 0o600, st.st_uid == geteuid(), st.st_nlink == 1, st.st_size >= 0 else { throw Failure.unsafeRepository }
  guard st.st_size <= Self.maxBytes else { throw Failure.repositoryTooLarge }
  var snap = BIFileSnapshot()
  let result = path.withCString { bi_snapshot_limited($0,deadline,UInt64(Self.maxBytes),&snap) }
  try checkDeadline(deadline)
  guard result == BI_OK else { throw Failure.snapshotFailed }
  let hash = withUnsafeBytes(of:&snap.sha256) { Array($0) }
  return RepositoryFileObservation(snapshot:snap,rawSHA256:hash)
 }
 /// Pass a single absolute C monotonic deadline derived once from the outer frame remaining budget.
 /// Filesystem and decode calls are checked after return but cannot be interrupted.
 func read(deadline: UInt64) throws -> RepositoryObservation {
  guard !closed else { throw Failure.closed }
  do {
   guard !Task.isCancelled else { throw Failure.closed }
   try checkDeadline(deadline)
   try checkPins()
   try checkDeadline(deadline)
   let before = try snapshot(path:repoPath,deadline:deadline)
   let bytes = try BoundedFixtureRead.read(repoPath,limit:Self.maxBytes)
   try checkDeadline(deadline)
   guard Array(SHA256.hash(data:bytes)) == before.rawSHA256 else { throw Failure.repositoryChanged }
   let records:[Profile]
   do { records = try JSONDocumentStore<Profile>.decode(bytes) } catch { throw Failure.decodingFailed }
   try checkDeadline(deadline)
   let after = try snapshot(path:repoPath,deadline:deadline)
   try checkPins()
   guard before == after else { throw Failure.repositoryChanged }
   var ids = Set<UUID>()
   for record in records { guard ids.insert(record.id).inserted else { throw Failure.duplicateID } }
   guard let profile = records.first(where:{$0.id == expectedSpec.profileID}) else { throw Failure.missingProfile }
   #if SAFARIER_BOUND_LOCAL_CANDIDATE
   if expectedSpec.registeredInteractive {
    guard !expectedSpec.backgroundAutomation, !expectedSpec.probe,
          profile.followProxyLanguages || expectedSpec.languages == profile.languages,
          profile.followProxyTimeZone || expectedSpec.timeZoneIdentifier == profile.timeZoneIdentifier else { throw Failure.profileDenied }
   } else {
    guard !profile.followProxyLanguages, !profile.followProxyTimeZone,
          expectedSpec.spiOverride == nil, expectedSpec.backgroundAutomation,
          expectedSpec.startURL == URL(string:"about:blank") else { throw Failure.profileDenied }
   }
   #else
   guard !profile.followProxyLanguages, !profile.followProxyTimeZone,
         expectedSpec.spiOverride == nil, expectedSpec.backgroundAutomation,
         expectedSpec.startURL == URL(string:"about:blank") else { throw Failure.profileDenied }
   #endif
   guard let document = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
         let rawRecords = document["records"] as? [[String: Any]],
         let rawProfile = rawRecords.first(where: { ($0["id"] as? String)?.uppercased() == profile.id.uuidString }) else { throw Failure.profileDenied }
   if let rawSPI = rawProfile["spi"] {
    guard let names = rawSPI as? [String], Set(names).count == names.count,
          Set(names).isSubset(of: Set(SPIFeatures.tokens.map(\.name))) else { throw Failure.profileDenied }
   }
   try profile.validate()
   var dependencies: [String: RepositoryFileObservation] = [:]
   func readDependency<T: Codable & Sendable & Identifiable>(_ name: String, type: T.Type) throws -> [T] where T.ID == UUID {
    let path = URL(fileURLWithPath: repoPath).deletingLastPathComponent().appendingPathComponent(name).path
    let first = try snapshot(path:path,deadline:deadline)
    let data = try BoundedFixtureRead.read(path,limit:Self.maxBytes)
    try checkDeadline(deadline)
    guard Array(SHA256.hash(data:data)) == first.rawSHA256 else { throw Failure.repositoryChanged }
    let records: [T]
    do { records = try JSONDocumentStore<T>.decode(data) } catch { throw Failure.decodingFailed }
    let last = try snapshot(path:path,deadline:deadline)
    guard first == last, Set(records.map(\.id)).count == records.count else { throw Failure.repositoryChanged }
    dependencies[name] = first
    return records
   }
   let proxies: [ProxySettings] = try profile.proxyID == nil ? [] : readDependency("proxies.json",type:ProxySettings.self)
   let subscriptions: [Subscription] = try profile.subscriptionID == nil ? [] : readDependency("subscriptions.json",type:Subscription.self)
   let plan: RunnerPreparationPlan
   do {
    plan = try RunnerPreparationPlan.resolve(profile:profile,spec:expectedSpec,proxyReader:{ id in proxies.first { $0.id == id } },boundNodeReader:{ requested in
     guard let id=requested.subscriptionID else { return nil }
     guard let subscription=subscriptions.first(where: { $0.id == id }), let name=requested.nodeName,
           let node=subscription.nodes.first(where: { $0.name == name }) else { throw Failure.profileDenied }
     return (subscription,node)
    })
   } catch { throw Failure.profileDenied }
   let afterDependencies = try snapshot(path:repoPath,deadline:deadline)
   try checkPins()
   guard afterDependencies == before else { throw Failure.repositoryChanged }
   let result = RepositoryObservation(file:before,rawBytes:bytes,records:records,profile:profile,spec:expectedSpec,
       dependencies:dependencies,proxy:plan.proxy,subscription:plan.boundNode?.subscription,node:plan.boundNode?.node)
   if let baseline, baseline != result { throw Failure.repositoryChanged }
   try checkDeadline(deadline)
   guard !Task.isCancelled else { throw Failure.closed }
   baseline = result
   return result
  } catch {
   closed = true
   throw error
  }
 }
 func release() { closed = true; lock?.finish() }
}
