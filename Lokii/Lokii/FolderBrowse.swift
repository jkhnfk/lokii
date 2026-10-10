import AppKit

/// 「浏览模式」的目录读取与空格键判定逻辑。
///
/// 空格键在 Lokii 里承担 macOS Finder 的 Quick Look 角色：选中文件时弹出预览面板，
/// 选中文件夹时则就地展开——结果列表切换成该文件夹的内容（浏览模式），
/// 之后用 ⌘↑ 逐级返回、⌘↓ 继续进入。
///
/// 这里放的是与窗口无关的纯逻辑：列目录、排序、过滤、以及「这次空格该干什么」的
/// 判定规则。`SearchWindow` 只负责把结果接到界面上，`tests/space_preview_browse.swift`
/// 则直接编译本文件做断言。

/// 目录里的一个条目。
struct BrowseEntry: Equatable {
    let name: String
    let path: String
    /// 磁盘上的原始类型——`.app` 这类包也是目录。
    let isDirectory: Bool
    /// 是不是包（`.app`、`.rtfd`…）：Finder 把它们当文件看待（空格预览而不是展开）。
    let isPackage: Bool
    let size: UInt64
    let created: UInt64
    let modified: UInt64

    /// 能否作为「文件夹」展开浏览：目录、且不是包。
    var isContainer: Bool { isDirectory && !isPackage }
}

/// 结果列表的排序键，与表格列一一对应。
enum BrowseSortKey: String {
    case name, path, modified, size
}

enum FolderBrowse {
    /// 单次列目录的条目上限：超大目录不至于把主线程卡住。
    static let defaultMaxEntries = 5000

    /// 一次列目录的结果；`truncated` 表示条目数触顶被截断。
    struct Listing: Equatable {
        let entries: [BrowseEntry]
        let truncated: Bool
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey,
        .creationDateKey, .contentModificationDateKey, .isHiddenKey,
    ]

    /// 读取 `folder` 的直接子项并排好序；返回 `nil` 表示该目录读不出来（权限、不存在…）。
    static func listing(in folder: String,
                        includeHidden: Bool,
                        maxEntries: Int = defaultMaxEntries) -> Listing? {
        let url = URL(fileURLWithPath: folder)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else { return nil }

        var entries: [BrowseEntry] = []
        var truncated = false
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(resourceKeys))
            // 隐藏项按配置放行；父目录自身是否隐藏不影响子项，所以只看条目自己的标记
            if !includeHidden, values?.isHidden == true { continue }
            if entries.count >= maxEntries {
                truncated = true
                break
            }
            entries.append(BrowseEntry(
                name: child.lastPathComponent,
                path: child.path,
                isDirectory: values?.isDirectory ?? false,
                isPackage: values?.isPackage ?? false,
                size: UInt64(values?.fileSize ?? 0),
                created: UInt64(values?.creationDate?.timeIntervalSince1970 ?? 0),
                modified: UInt64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            ))
        }

        return Listing(entries: sorted(entries, by: .name, ascending: true), truncated: truncated)
    }

    /// 只要条目列表（不关心是否被截断时的便捷入口）。
    static func entries(in folder: String,
                        includeHidden: Bool,
                        maxEntries: Int = defaultMaxEntries) -> [BrowseEntry] {
        listing(in: folder, includeHidden: includeHidden, maxEntries: maxEntries)?.entries ?? []
    }

    /// 排序：文件夹永远排在文件前面，其余按 `key` 比较（Finder 的默认观感）。
    static func sorted(_ entries: [BrowseEntry], by key: BrowseSortKey, ascending: Bool) -> [BrowseEntry] {
        entries.sorted { a, b in
            if a.isContainer != b.isContainer { return a.isContainer }
            let cmp: ComparisonResult
            switch key {
            case .name:
                cmp = a.name.localizedStandardCompare(b.name)
            case .path:
                let pathA = (a.path as NSString).deletingLastPathComponent
                let pathB = (b.path as NSString).deletingLastPathComponent
                cmp = pathA.localizedStandardCompare(pathB)
            case .modified:
                cmp = compare(a.modified, b.modified)
            case .size:
                cmp = compare(a.size, b.size)
            }
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }

    /// 上一级目录；已经到根目录（或路径已经归一化到顶）时返回 `nil`。
    static func parent(of path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        return parent == standardized ? nil : parent
    }

    /// 按搜索框里的关键字过滤：大小写/变音符不敏感的子串匹配；空串返回全部。
    static func filter(_ entries: [BrowseEntry], query: String) -> [BrowseEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { matches($0, query: trimmed) }
    }

    static func matches(_ entry: BrowseEntry, query: String) -> Bool {
        entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// `path` 是不是一个可以展开浏览的文件夹（目录且不是包）。
    ///
    /// 浏览模式靠 `BrowseEntry.isContainer` 判定；搜索模式只有 Rust 侧给的 `isDir`，
    /// 而它会把手选成一个目录的 `.app` 也算进去，所以这里再向磁盘核对一次。
    static func isContainer(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return false
        }
        return (values.isDirectory ?? false) && !(values.isPackage ?? false)
    }
}

// MARK: - 空格键判定

/// 键盘焦点落在哪里。
enum FocusTarget: Equatable {
    case searchField
    case results
    case other
}

/// 当前选中项的种类。
enum SelectionKind: Equatable {
    case none
    case file
    case folder
}

/// 一次空格键的意图。
enum SpaceIntent: Equatable {
    case passThrough    // 交回 AppKit：搜索框里打字、焦点在别处、没有选中项…
    case closePreview   // 已经在预览 → 关掉
    case preview        // 选中文件 → 弹 Quick Look
    case enterFolder    // 选中文件夹 → 展开浏览
}

/// 空格键的判定规则（与窗口实现分离，便于单测）。
enum SpaceRules {
    /// 焦点归属：搜索框的 field editor 拿到焦点时算搜索框，落在表格上算结果列表。
    static func focusTarget(firstResponder: NSResponder?,
                            searchFieldEditor: NSResponder?,
                            isResultsResponder: Bool) -> FocusTarget {
        if let editor = searchFieldEditor, firstResponder === editor { return .searchField }
        return isResultsResponder ? .results : .other
    }

    /// 选中项种类；`isSelectedContainer` 为 `nil` 表示没有选中行。
    static func selectionKind(selectedRow: Int, isSelectedContainer: Bool?) -> SelectionKind {
        guard selectedRow >= 0, let isContainer = isSelectedContainer else { return .none }
        return isContainer ? .folder : .file
    }

    static func intent(focus: FocusTarget, selection: SelectionKind, isPreviewing: Bool) -> SpaceIntent {
        // 搜索框里的空格是空格字符；焦点在别处（按钮、信息面板…）时留给 AppKit 默认行为
        guard focus == .results else { return .passThrough }
        if isPreviewing { return .closePreview }
        switch selection {
        case .none: return .passThrough
        case .folder: return .enterFolder
        case .file: return .preview
        }
    }
}

