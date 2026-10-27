import Foundation
import Darwin

private let maxChromeLocalStateBytes = 32 * 1024 * 1024

func validChromeProfileName(_ name: String) -> Bool {
    !name.isEmpty && name.unicodeScalars.count <= 128 &&
        name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

private struct ChromeProfileDirectoryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

struct ChromeProfileSelection {
    let name: String
    let directory: String
    let dataRoot: URL
    fileprivate let identity: ChromeProfileDirectoryIdentity

    var path: URL { dataRoot.appendingPathComponent(directory, isDirectory: true) }
    var json: [String: Any] { ["name": name, "directory": directory, "path": path.path] }

    // Chrome may fall back to its default when a requested profile disappears.
    // Revalidate before navigating the marker window to any requested website.
    func revalidate() throws {
        do {
            let current = try resolveChromeProfile(name: name, dataRoot: dataRoot)
            guard current.directory == directory, current.identity == identity else {
                throw profileError("PROFILE_CHANGED", "所选Chrome profile目录或名称映射发生变化；未继续导航或连接")
            }
        } catch {
            throw profileError("PROFILE_CHANGED", "所选Chrome profile目录或名称映射发生变化；未继续导航或连接")
        }
    }
}

func defaultChromeUserDataRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
}

func resolveChromeProfile(name: String, dataRoot: URL = defaultChromeUserDataRoot()) throws -> ChromeProfileSelection {
    guard validChromeProfileName(name) else { throw HelperFailure.invalidArgument }
    guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/") else {
        throw profileError("PROFILE_INVALID", "Chrome profile根目录无效")
    }
    let data = try readChromeLocalState(dataRoot.appendingPathComponent("Local State"))
    let entries: [String: Any]
    do {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            throw profileError("PROFILE_METADATA_INVALID", "无法解析Chrome profile名称映射")
        }
        entries = cache
    } catch { throw profileError("PROFILE_METADATA_INVALID", "无法安全解析Chrome Local State；不会输出文件内容") }
    let matches = entries.compactMap { directory, raw -> String? in
        guard let record = raw as? [String: Any], record["name"] as? String == name else { return nil }
        return directory
    }
    guard !matches.isEmpty else {
        throw profileError("PROFILE_NOT_FOUND", "未找到该显示名称的现有Chrome profile；未创建profile或回退到其他账号")
    }
    guard matches.count == 1 else {
        throw profileError("PROFILE_AMBIGUOUS", "Chrome profile显示名称重名，无法安全选择；请先在Chrome中改为唯一名称")
    }
    let directory = matches[0]
    guard validChromeProfileDirectory(directory) else {
        throw profileError("PROFILE_INVALID", "Chrome profile目录标识无效；不接受路径或系统/访客profile")
    }
    let normalized = dataRoot.standardizedFileURL
    let identity = try chromeProfileDirectoryIdentity(normalized.appendingPathComponent(directory, isDirectory: true))
    return ChromeProfileSelection(name: name, directory: directory, dataRoot: normalized, identity: identity)
}

func validChromeProfileDirectory(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
        name != "Guest Profile" && name != "System Profile" &&
        !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

private func chromeProfileDirectoryIdentity(_ url: URL) throws -> ChromeProfileDirectoryIdentity {
    var info = stat()
    guard lstat(url.path, &info) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else {
        throw profileError("PROFILE_UNAVAILABLE", "所选Chrome profile目录不存在、不是当前用户的普通目录或是符号链接；未新建目录")
    }
    return ChromeProfileDirectoryIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
}

private func readChromeLocalState(_ url: URL) throws -> Data {
    // NONBLOCK prevents a crafted FIFO from blocking before fstat can reject it.
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw profileError("PROFILE_METADATA_INVALID", "无法安全读取Chrome Local State") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maxChromeLocalStateBytes else {
        throw profileError("PROFILE_METADATA_INVALID", "Chrome Local State类型、所有权或大小不符合读取边界")
    }
    do {
        let data = try handle.read(upToCount: maxChromeLocalStateBytes + 1) ?? Data()
        guard data.count <= maxChromeLocalStateBytes else {
            throw profileError("PROFILE_METADATA_INVALID", "Chrome Local State超过读取边界")
        }
        return data
    } catch { throw profileError("PROFILE_METADATA_INVALID", "无法安全读取Chrome Local State；不会输出文件内容") }
}

func validChromeProfileMarkerPath(_ path: String) -> Bool {
    let prefix = "mcc-profile-", suffix = ".html"
    let filename = URL(fileURLWithPath: path).lastPathComponent
    guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.hasSuffix("/"),
          !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
          !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
          filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
    let nonce = filename.dropFirst(prefix.count).dropLast(suffix.count)
    return (16...64).contains(nonce.count) && nonce.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") }
}

func createChromeProfileMarker(path: String) throws -> URL {
    guard validChromeProfileMarkerPath(path) else { throw HelperFailure.invalidArgument }
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw profileError("PROFILE_MARKER_FAILED", "无法创建本次私有profile窗口标记") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
        // No script, profile name, account data or network resource in this page.
        try handle.write(contentsOf: Data("<!doctype html><meta charset=utf-8><title>MCC profile startup</title><p>MCC profile startup</p>".utf8))
    } catch { throw profileError("PROFILE_MARKER_FAILED", "无法写入本次私有profile窗口标记") }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
}

func chromeProfileLaunchArguments(application: URL, profile: ChromeProfileSelection, marker: String) throws -> [String] {
    guard application.isFileURL, application.path.hasPrefix("/"), application.pathExtension == "app",
          let url = URL(string: marker), url.isFileURL, url.query == nil, url.fragment == nil,
          (url.host == nil || url.host == ""), url.user == nil, url.password == nil, url.port == nil,
          validChromeProfileMarkerPath(url.path) else {
        throw profileError("PROFILE_INVALID", "profile启动只接受本次私有文件标记页")
    }
    return ["-n", "-a", application.path, "--args", "--user-data-dir=\(profile.dataRoot.path)",
            "--profile-directory=\(profile.directory)", "--ignore-profile-directory-if-not-exists", "--new-window", marker]
}

private func profileError(_ code: String, _ message: String) -> HelperFailure {
    HelperFailure(code: code, message: message)
}

// `matches` must come from the native AXDocument marker check. Include old
// windows in that check too: a moved/duplicated marker must never authorize them.
func selectProfileMarkerWindow(before: Set<ChromeWindowIdentity>, matches: [ChromeWindow]) throws -> TargetWindow? {
    guard matches.count <= 1 else {
        throw profileError("PROFILE_WINDOW_AMBIGUOUS", "多个Chrome窗口暴露同一启动标记，拒绝猜测")
    }
    guard let window = matches.first else { return nil }
    guard window.layer == 0, window.target.bundleId == "com.google.Chrome", window.target.pid > 0,
          window.target.windowId > 0 else {
        throw profileError("PROFILE_WINDOW_UNVERIFIED", "profile标记未对应到普通Chrome窗口")
    }
    let identity = ChromeWindowIdentity(pid: window.target.pid, windowID: window.target.windowId)
    guard !before.contains(identity) else {
        throw profileError("PROFILE_WINDOW_NOT_NEW", "启动标记出现在已有窗口；未移动或导航该窗口")
    }
    return window.target
}
