import AppKit

/// 把当前选中项交给 LaunchBar，交给用户在 LaunchBar 里继续选择后续动作。
///
/// LaunchBar 的交互模型是「拿到一个条目 → 展示动作列表」，这里复用它自带的
/// 两种接收入口，按本机实测的可靠性排序：
///
///  1. `x-launchbar:select?file=<path>`，即 LaunchBar 内置的 "Go to" 搜索模板
///     （`Contents/Resources/SearchTemplates.plist` 第 20 项）。纯 URL Scheme，
///     零权限、零依赖；查询值收的是 POSIX 路径而非 `file://` URL（旁证：LaunchBar
///     自带 Automator 动作 `Browse` 用 `path=%@`／`text=%@` 拼它的 `browse` URL）。
///     实测 `NSWorkspace.open` 返回 `true`，LaunchBar 随即成为前台 App，且没有任何
///     外部 App 被唤起——即条目是「停在 LaunchBar 里等待挑动作」，而非被打开。
///     同族的 `x-launchbar:browse?path=<path>` 语义是「浏览该路径的内容」，
///     与这里「把条目交给用户继续选动作」的目标不同，故不采用。
///  2. `Send to LaunchBar` Service（LaunchBar `Info.plist` 中
///     `NSMessage = sendToLaunchBar`，Instant Send 的官方入口），仅在 Scheme
///     不可用时兜底。原因是服务名可能被同名服务遮蔽：本机 `~/Library/Services`
///     下的 Automator 服务也注册了 "Send to LaunchBar"（只接受纯文本），
///     `NSPerformService` 可能选中它并「返回 true 却什么都没发生」，
///     因此它的返回值不能当作可靠的成功信号。
///
/// 两条路都不可用时返回 `false`，调用方据此报错并保留当前选中项。
enum LaunchBar {

    /// LaunchBar 的 bundle identifier（Objective Development）。
    static let bundleIdentifier = "at.obdev.LaunchBar"

    /// Service 菜单中显示的名字，也是服务数据库里的键名。
    private static let serviceName = "Send to LaunchBar"

    /// `x-launchbar:select?file=<path>`：LaunchBar 内置 "Go to" 模板使用的 URL 形式。
    private static let selectURLPrefix = "x-launchbar:select?file="

    /// 专用命名剪贴板：把条目交给 Service 时不污染用户自己的剪贴板。
    private static let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.lokii.launchbar"))

    /// LaunchBar 是否已安装。
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// 把 `urls` 交给 LaunchBar。返回 `true` 表示已成功发起交接。
    ///
    /// 多选时以第一个为准：`select` URL 只携带单个路径，先保证 LaunchBar 明确
    /// 收到条目；若 Scheme 不可用，才退到能一次交付整组的 Service。
    @discardableResult
    static func send(urls: [URL]) -> Bool {
        guard !urls.isEmpty, isInstalled else { return false }
        if let first = urls.first, openViaSelectURL(first) { return true }
        return performService(with: urls)
    }

    // MARK: - Mechanism 1: URL scheme

    /// 走 `x-launchbar:select?file=…`，交给 LaunchBar 自己打开该条目。
    private static func openViaSelectURL(_ url: URL) -> Bool {
        // 路径作为 query 值，需转义会截断 query 的字符与 `%` 本身
        // （否则路径里的字面 `%` 会被当成残缺的百分号转义）。
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?%")
        guard let encoded = url.path.addingPercentEncoding(withAllowedCharacters: allowed),
              let selectURL = URL(string: selectURLPrefix + encoded) else { return false }
        return NSWorkspace.shared.open(selectURL)
    }

    // MARK: - Mechanism 2: Services

    /// 走 `NSPerformService`。Service 未启用、被同名服务遮蔽或 LaunchBar 不可用
    /// 时返回 `false`，由调用方决定怎么提示。
    ///
    /// 剪贴板上每个条目同时写入 `public.file-url` 与 `public.utf8-plain-text`：
    /// 同名服务里既有只认 file URL 的（LaunchBar 官方 `sendToLaunchBar`），
    /// 也有只认纯文本的（Automator 生成的同名服务），两种都能通过类型检查。
    private static func performService(with urls: [URL]) -> Bool {
        let items: [NSPasteboardItem] = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return NSPerformService(serviceName, pasteboard)
    }
}
