import Foundation

/// 静默安装随 App 打包的 `lokii` 命令行工具。
///
/// 应用启动时调用：尽力把 `Lokii.app/Contents/Resources/bin/lokii`
/// 链接到用户 PATH 中的某个目录，使安装 App 后可直接在终端执行 `lokii`
/// 返回搜索结果，无需任何额外操作。
///
/// 设计要点（对应「静默、零操作、不改动现有功能」）：
/// - 幂等：已存在指向同一二进制的有效链接时立即返回，不重复操作。
/// - 自愈：App 移动或被删除链接后，下次启动会自动重建。
/// - 安全：只替换符号链接，绝不覆盖同名的真实文件。
/// - 静默：任何失败（无写权限等）都直接忽略，不打扰用户，也不影响 App 其余功能。
enum CommandLineInstaller {

    /// 随包的 CLI 在 .app 内的相对路径。
    private static let bundledRelativePath = "Contents/Resources/bin/lokii"

    /// 链接文件名。
    private static let linkName = "lokii"

    /// 候选安装目录（按优先级）。`/usr/local/bin` 是 macOS 默认 PATH 的一部分。
    private static var candidateDirectories: [URL] {
        var dirs: [URL] = [URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)]
        dirs.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true))
        return dirs
    }

    /// 在应用启动时调用。幂等，且永不抛出。
    static func installIfNeeded() {
        guard let binary = bundledBinaryURL() else { return }

        // 已就绪：存在指向该二进制的有效链接。
        if candidateDirectories.contains(where: {
            isLink($0.appendingPathComponent(linkName), pointingTo: binary)
        }) {
            return
        }

        // 挑选第一个可写目录完成安装。
        for dir in candidateDirectories where ensureWritableDirectory(dir) {
            placeLink(named: linkName, in: dir, pointingTo: binary)
            return
        }
    }

    // MARK: - Helpers

    /// 随包 CLI 的绝对路径；未随包分发（如 `swift run` 开发期）时返回 nil。
    private static func bundledBinaryURL() -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(bundledRelativePath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// 判断 `link` 是否为指向 `target` 的符号链接。
    private static func isLink(_ link: URL, pointingTo target: URL) -> Bool {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let resolvedDestination = URL(fileURLWithPath: destination).resolvingSymlinksInPath()
        let resolvedTarget = target.resolvingSymlinksInPath()
        return resolvedDestination.path == resolvedTarget.path
    }

    /// 确保目录存在且可写；不可写时返回 false（不尝试提权，保持静默）。
    private static func ensureWritableDirectory(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return fm.isWritableFile(atPath: dir.path)
    }

    /// 在 `dir` 内创建/更新名为 `name`、指向 `target` 的符号链接。
    /// 已存在的同名真实文件会被保留（不覆盖），此时放弃本次安装。
    private static func placeLink(named name: String, in dir: URL, pointingTo target: URL) {
        let fm = FileManager.default
        let link = dir.appendingPathComponent(name)

        if isSymlink(link) {
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            return // 真实文件，避免破坏用户数据
        }

        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// 仅判断路径本身是否为符号链接（不跟随链接目标，故对悬空链接同样成立）。
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }
}
