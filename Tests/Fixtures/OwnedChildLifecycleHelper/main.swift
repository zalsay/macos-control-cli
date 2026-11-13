import Foundation
import Darwin

@main struct Helper {
    static func main() {
        alarm(15)
        if CommandLine.arguments.contains("ignore") { signal(SIGTERM, SIG_IGN) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(2) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = CommandLine.arguments.contains("wildcard") ? INADDR_ANY : in_addr_t(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { exit(3) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { exit(4) }
        print(UInt16(bigEndian: addr.sin_port)); fflush(stdout)
        fputs("fixture-stderr\n", stderr); fflush(stderr)
        var byte: UInt8 = 0
        while read(STDIN_FILENO, &byte, 1) > 0 {}
        close(fd)
    }
}
