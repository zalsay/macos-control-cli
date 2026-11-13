import Foundation
import Darwin

/// Controlled fixture only. Callers establish root provenance and pin each parent.
final class PrivateDirectoryPin {
 enum Failure: Error { case invalidDirectory }
 private let path: String
 private let descriptor: Int32
 private let device: dev_t
 private let inode: ino_t

 init(path: URL) throws {
  let name = path.path
  var before = stat(), held = stat(), after = stat()
  guard lstat(name,&before) == 0, Self.safe(before) else { throw Failure.invalidDirectory }
  let fd = open(name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw Failure.invalidDirectory }
  guard fstat(fd,&held) == 0, lstat(name,&after) == 0,
        Self.safe(held), Self.safe(after), Self.same(before,held), Self.same(held,after) else {
   close(fd); throw Failure.invalidDirectory
  }
  self.path = name; self.descriptor = fd; self.device = held.st_dev; self.inode = held.st_ino
 }
 deinit { close(descriptor) }
 func matches() -> Bool {
  var held = stat(), current = stat()
  guard fstat(descriptor,&held) == 0, lstat(path,&current) == 0,
        Self.safe(held), Self.safe(current), Self.same(held,current) else { return false }
  return held.st_dev == device && held.st_ino == inode
 }
 private static func safe(_ s: stat) -> Bool {
  (s.st_mode & S_IFMT) == S_IFDIR && (s.st_mode & 0o7777) == 0o700 && s.st_uid == geteuid()
 }
 private static func same(_ a: stat, _ b: stat) -> Bool {
  a.st_dev == b.st_dev && a.st_ino == b.st_ino
 }
}
