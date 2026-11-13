import Foundation
import Darwin

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
guard args.count == 4, args[1] == "run", args[2] == "-c" else { exit(31) }
let isOwned = args[3] == "stdin"
if isOwned && Set(env.keys).subtracting(["__CF_USER_TEXT_ENCODING"]) != Set(["PATH", "LC_ALL"]) { exit(31) }
if URL(fileURLWithPath: args[0]).lastPathComponent == "blocked-helper" { sleep(5); exit(0) }
let data = isOwned ? FileHandle.standardInput.readDataToEndOfFile() : ((try? Data(contentsOf: URL(fileURLWithPath: args[3]))) ?? Data())
guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let inbound = (json["inbounds"] as? [[String: Any]])?.first,
      let port = inbound["listen_port"] as? Int,
      let outbound = (json["outbounds"] as? [[String: Any]])?.first,
      let password = outbound["password"] as? String else { exit(32) }
if password == "early" { exit(7) }
if password == "timeout" { sleep(5); exit(0) }
if password == "ignore" || password == "late" { signal(SIGTERM, SIG_IGN) }
let fd = socket(AF_INET, SOCK_STREAM, 0)
var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
if ok != 0 || listen(fd, 4) != 0 { exit(33) }
if password == "late" { sleep(1); exit(0) }
if password == "ignore" { sleep(4); exit(0) }
while true { sleep(1) }
