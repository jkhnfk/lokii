#!/usr/bin/env swift
// ==============================================================================
// space_preview_browse —— `Lokii/Lokii/FolderBrowse.swift` 的回归测试
//
// 用法（在仓库根目录下执行）:
//   swift tests/space_preview_browse.swift
//
// 为什么长这样：被测类型在 app target 里，脚本没法直接 import，所以这里把生产
// 源码 `FolderBrowse.swift` 原样读进来，拼上下面的断言，生成一个临时 `main.swift`
// 用 swiftc 编出来执行。断言跑的就是生产实现本体，不存在「测试里另抄一份实现」的漂移。
//
// 覆盖范围：
//   1. `FolderBrowse.parent(of:)`：普通路径、根目录、`~` 展开
//   2. `FolderBrowse.sorted(_:by:ascending:)`：文件夹恒排在文件前（包按文件看待），
//      名称/路径/修改时间/大小四种键的升降序，名称按 Finder 口径（数字感知）
//   3. `FolderBrowse.filter/matches`：空串与全空白放行、大小写与变音符不敏感、子串命中
//   4. `FolderBrowse.listing(in:includeHidden:maxEntries:)`：在真实临时目录上列目录
//      （隐藏项按配置放行、触顶截断、读不出来的目录返回 nil），
//      以及 `entries(in:)` 便捷入口与之一致
//   5. `FolderBrowse.isContainer(at:)`：普通目录可展开，包与普通文件不可
//   6. `SpaceRules`：焦点归属、选中项种类、以及空格键「这次该干什么」的整张判定表
//   7. 跨文件对齐：`BrowseSortKey` 的取值与 `SearchWindow` 表格列的排序键一一对应
//      （表头排序描述符的 key 直接拿去构造 BrowseSortKey，对不上就会静默退回按名称排）
//
// 不覆盖（依赖真实窗口与 Quick Look 面板，只能手工验证）：空格真正弹出预览面板、
// ⌘↑/⌘↓ 的焦点接力、浏览模式与搜索结果之间的来回切换。本测试不创建 NSWindow，
// 因此在无窗口服务器的环境（CI、SSH）下也能跑。
// ==============================================================================

import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/
    .deletingLastPathComponent()   // 仓库根目录

let productionFile = repoRoot.appendingPathComponent("Lokii/Lokii/FolderBrowse.swift")

// MARK: - 测试驱动（编译进临时可执行文件，与生产代码同一个模块）

let driverSource = #"""
// ---- 本段由 tests/space_preview_browse.swift 生成 ----

import Foundation
import AppKit

var checks = 0
var failures: [String] = []

func expect(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
    checks += 1
    guard !condition else { return }
    let extra = detail()
    failures.append(extra.isEmpty ? label : "\(label) — \(extra)")
}

/// 把名字列表压成一行，只在断言失败时用于打印。
func describe(_ names: [String]) -> String {
    "[" + names.joined(separator: ", ") + "]"
}

/// 造一个条目，省得每条断言都写全字段。
func entry(_ name: String,
           path: String? = nil,
           dir: Bool = false,
           package: Bool = false,
           size: UInt64 = 0,
           modified: UInt64 = 0) -> BrowseEntry {
    BrowseEntry(name: name,
                path: path ?? "/fixture/" + name,
                isDirectory: dir,
                isPackage: package,
                size: size,
                created: 0,
                modified: modified)
}

func describe(_ sortKey: BrowseSortKey) -> String { sortKey.rawValue }

func describe(_ focus: FocusTarget) -> String {
    switch focus {
    case .searchField: return "搜索框"
    case .results: return "结果列表"
    case .other: return "别处"
    }
}

func describe(_ selection: SelectionKind) -> String {
    switch selection {
    case .none: return "没有选中项"
    case .file: return "选中文件"
    case .folder: return "选中文件夹"
    }
}

func describe(_ intent: SpaceIntent) -> String {
    switch intent {
    case .passThrough: return "交给 AppKit"
    case .closePreview: return "关掉预览"
    case .preview: return "弹出预览"
    case .enterFolder: return "展开文件夹"
    }
}

/// 正则取第一个捕获组，供最后的跨文件对齐检查用。
func capture(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
        guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

let repoRootPath = "__REPO_ROOT__"
"""#

let driverAssertions = #"""
// ============================== 断言开始 ==============================

// MARK: - 1. 上一级目录

let parentCases: [(name: String, path: String, expected: String?)] = [
    ("普通文件", "/Users/me/Notes.txt", "/Users/me"),
    ("普通目录", "/Users/me/Projects", "/Users/me"),
    ("根目录下的条目", "/tmp", "/"),
    ("已经在根目录", "/", nil),
]

for item in parentCases {
    let actual = FolderBrowse.parent(of: item.path)
    expect(actual == item.expected,
           "parent(of:) 处理\(item.name)",
           detail: "得到 \(actual ?? "nil")，期望 \(item.expected ?? "nil")")
}

// 用户手输的 ~ 会先展开再取上级，和 Finder 里「回到上一级」的观感一致
expect(FolderBrowse.parent(of: "~/Notes.md") == NSHomeDirectory(),
       "parent(of:) 会先展开 ~",
       detail: "得到 \(FolderBrowse.parent(of: "~/Notes.md") ?? "nil")，期望 \(NSHomeDirectory())")

// MARK: - 2. 排序

let mixed = [
    entry("beta.txt"), entry("alpha.txt"), entry("zeta", dir: true),
    entry("pack.app", dir: true, package: true),
]

expect(describe(FolderBrowse.sorted(mixed, by: .name, ascending: true).map(\.name))
        == describe(["zeta", "alpha.txt", "beta.txt", "pack.app"]),
       "名称升序：文件夹在前，包按文件参与排序")
expect(describe(FolderBrowse.sorted(mixed, by: .name, ascending: false).map(\.name))
        == describe(["zeta", "pack.app", "beta.txt", "alpha.txt"]),
       "名称降序：文件夹依旧在最前，文件组整体倒序")

let numbered = [entry("item10.txt"), entry("item2.txt"), entry("item1.txt")]
expect(describe(FolderBrowse.sorted(numbered, by: .name, ascending: true).map(\.name))
        == describe(["item1.txt", "item2.txt", "item10.txt"]),
       "名称排序是数字感知的（Finder 口径，item2 在 item10 前）")

let pathed = [entry("b.txt", path: "/z/b.txt"), entry("a.txt", path: "/y/a.txt")]
expect(describe(FolderBrowse.sorted(pathed, by: .path, ascending: true).map(\.name))
        == describe(["a.txt", "b.txt"]),
       "按路径升序")
expect(describe(FolderBrowse.sorted(pathed, by: .path, ascending: false).map(\.name))
        == describe(["b.txt", "a.txt"]),
       "按路径降序")

let sized = [entry("small.bin", size: 10), entry("big.bin", size: 100), entry("huge.bin", size: 1000)]
expect(describe(FolderBrowse.sorted(sized, by: .size, ascending: true).map(\.name))
        == describe(["small.bin", "big.bin", "huge.bin"]),
       "按大小升序")
expect(describe(FolderBrowse.sorted(sized, by: .size, ascending: false).map(\.name))
        == describe(["huge.bin", "big.bin", "small.bin"]),
       "按大小降序")
expect(FolderBrowse.sorted(sized + [entry("dim", dir: true, size: 0)], by: .size, ascending: false)
        .first?.name == "dim",
       "按大小降序时文件夹仍然排在最前")

let dated = [entry("old.txt", modified: 100), entry("new.txt", modified: 900), entry("mid.txt", modified: 500)]
expect(describe(FolderBrowse.sorted(dated, by: .modified, ascending: true).map(\.name))
        == describe(["old.txt", "mid.txt", "new.txt"]),
       "按修改时间升序")
expect(describe(FolderBrowse.sorted(dated, by: .modified, ascending: false).map(\.name))
        == describe(["new.txt", "mid.txt", "old.txt"]),
       "按修改时间降序")
expect(FolderBrowse.sorted(dated, by: .name, ascending: false).count == dated.count,
       "排序不丢条目、不改条数")

// MARK: - 3. 按关键字过滤

let filterable = [entry("Report.pdf"), entry("café.md"), entry("notes.txt")]

expect(FolderBrowse.filter(filterable, query: "").count == filterable.count,
       "空串不过滤")
expect(FolderBrowse.filter(filterable, query: "   ").count == filterable.count,
       "全空白不过滤")
expect(describe(FolderBrowse.filter(filterable, query: "report").map(\.name)) == describe(["Report.pdf"]),
       "过滤大小写不敏感")
expect(describe(FolderBrowse.filter(filterable, query: "PORT").map(\.name)) == describe(["Report.pdf"]),
       "过滤命中的是子串，不必从头匹配")
expect(describe(FolderBrowse.filter(filterable, query: "cafe").map(\.name)) == describe(["café.md"]),
       "过滤变音符不敏感")
expect(describe(FolderBrowse.filter(filterable, query: "  report  ").map(\.name)) == describe(["Report.pdf"]),
       "过滤会裁掉关键字两头的空白")
expect(FolderBrowse.filter(filterable, query: "zzz").isEmpty,
       "没命中就返回空列表")
expect(FolderBrowse.matches(entry("Report.pdf"), query: "report"),
       "matches 与 filter 同口径")
expect(!FolderBrowse.matches(entry("Report.pdf"), query: "report.txt"),
       "matches 是子串匹配，不是前缀压缩")
"""#

let driverAssertions2 = #"""
// MARK: - 4. 真实目录上列目录

let fixtureRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("lokii-browse-\(UUID().uuidString)")
let subDir = fixtureRoot.appendingPathComponent("sub")
let emptyDir = fixtureRoot.appendingPathComponent("empty")
let packDir = fixtureRoot.appendingPathComponent("pack.app")
let alphaFile = fixtureRoot.appendingPathComponent("alpha.txt")

do {
    let manager = FileManager.default
    try manager.createDirectory(at: subDir, withIntermediateDirectories: true)
    try manager.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    try manager.createDirectory(at: packDir, withIntermediateDirectories: true)
    try "inside".write(to: packDir.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
    try "alpha".write(to: alphaFile, atomically: true, encoding: .utf8)
    try "beta".write(to: fixtureRoot.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
    try "hidden".write(to: fixtureRoot.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)
    try "secret".write(to: subDir.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
} catch {
    print("准备临时目录失败：\(error)")
    exit(2)
}
defer { try? FileManager.default.removeItem(at: fixtureRoot) }

let visible = FolderBrowse.listing(in: fixtureRoot.path, includeHidden: false, maxEntries: 100)
expect(visible != nil, "能读到临时目录")
expect(describe(visible?.entries.map(\.name) ?? [])
        == describe(["empty", "sub", "alpha.txt", "beta.txt", "pack.app"]),
       "列目录：文件夹在前、包按文件对待、隐藏项被挡掉",
       detail: "得到 \(describe(visible?.entries.map(\.name) ?? []))")
expect(visible?.truncated == false, "条目没触顶时 truncated 为 false")
expect(visible?.entries.first?.isContainer == true, "排在首位的是可展开的文件夹")
expect(visible?.entries.contains { $0.name == "pack.app" && !$0.isContainer } == true,
       "包虽然 isDirectory，但不算可展开的文件夹")
expect((visible?.entries.first { $0.name == "alpha.txt" }?.size ?? 0) == 5,
       "普通文件带上真实大小")
expect((visible?.entries.first { $0.name == "alpha.txt" }?.modified ?? 0) > 0,
       "普通文件带上真实修改时间")

let withHidden = FolderBrowse.listing(in: fixtureRoot.path, includeHidden: true, maxEntries: 100)
expect(withHidden?.entries.contains { $0.name == ".hidden.txt" } == true,
       "配置放行时包含隐藏项")
expect((withHidden?.entries.count ?? 0) == (visible?.entries.count ?? 0) + 1,
       "放行隐藏项后只多出隐藏的那一个")

let capped = FolderBrowse.listing(in: fixtureRoot.path, includeHidden: false, maxEntries: 3)
expect(capped?.truncated == true, "条目触顶时 truncated 为 true")
expect(capped?.entries.count == 3, "触顶时最多返回 maxEntries 条",
       detail: "得到 \(capped?.entries.count ?? -1) 条")

expect(FolderBrowse.entries(in: fixtureRoot.path, includeHidden: false, maxEntries: 100)
        == visible?.entries,
       "entries(in:) 与 listing(in:) 的条目完全一致")

expect(FolderBrowse.listing(in: emptyDir.path, includeHidden: false, maxEntries: 10)?.entries.isEmpty == true,
       "空目录返回空列表而不是 nil")
expect(FolderBrowse.listing(in: emptyDir.path, includeHidden: false, maxEntries: 10)?.truncated == false,
       "空目录不算触顶")
expect(FolderBrowse.listing(in: fixtureRoot.appendingPathComponent("nope").path,
                            includeHidden: false, maxEntries: 10) == nil,
       "不存在的目录返回 nil")
expect(FolderBrowse.listing(in: alphaFile.path, includeHidden: false, maxEntries: 10) == nil,
       "拿文件当目录读返回 nil")
expect(FolderBrowse.entries(in: fixtureRoot.appendingPathComponent("nope").path,
                            includeHidden: false, maxEntries: 10).isEmpty,
       "读不出来时 entries(in:) 退化成空列表")

// MARK: - 5. 能否展开

expect(FolderBrowse.isContainer(at: subDir.path), "普通目录可以展开")
expect(!FolderBrowse.isContainer(at: packDir.path), "包（.app）按文件对待，不展开")
expect(!FolderBrowse.isContainer(at: alphaFile.path), "普通文件不展开")
expect(!FolderBrowse.isContainer(at: fixtureRoot.appendingPathComponent("nope").path),
       "不存在的路径不展开")
expect(FolderBrowse.defaultMaxEntries > 0, "条目上限是正数")
"""#

let driverAssertions3 = #"""
// MARK: - 6. 空格键判定

let editor = NSView()
let elsewhere = NSView()

expect(SpaceRules.focusTarget(firstResponder: editor, searchFieldEditor: editor, isResultsResponder: false)
        == .searchField,
       "焦点在搜索框的 field editor 上 → 搜索框")
expect(SpaceRules.focusTarget(firstResponder: elsewhere, searchFieldEditor: editor, isResultsResponder: true)
        == .results,
       "焦点在表格上 → 结果列表")
expect(SpaceRules.focusTarget(firstResponder: elsewhere, searchFieldEditor: editor, isResultsResponder: false)
        == .other,
       "焦点在别处 → 别处")
expect(SpaceRules.focusTarget(firstResponder: elsewhere, searchFieldEditor: nil, isResultsResponder: true)
        == .results,
       "搜索框还没建好时不误判成搜索框")
expect(SpaceRules.focusTarget(firstResponder: nil, searchFieldEditor: editor, isResultsResponder: false)
        == .other,
       "没有 first responder 时不误判成搜索框")

let selectionCases: [(row: Int, container: Bool?, expected: SelectionKind)] = [
    (-1, nil, .none),
    (-1, false, .none),
    (-1, true, .none),
    (0, nil, .none),
    (0, false, .file),
    (0, true, .folder),
    (7, true, .folder),
]
for item in selectionCases {
    let actual = SpaceRules.selectionKind(selectedRow: item.row, isSelectedContainer: item.container)
    expect(actual == item.expected,
           "选中行 \(item.row) / 容器 \(item.container.map(String.init) ?? "nil") → \(describe(item.expected))",
           detail: "得到 \(describe(actual))")
}

let intentCases: [(name: String, focus: FocusTarget, selection: SelectionKind, previewing: Bool, expected: SpaceIntent)] = [
    ("搜索框里的空格是空格字符", .searchField, .file, false, .passThrough),
    ("搜索框里选中文件夹也一样", .searchField, .folder, false, .passThrough),
    ("焦点在别处时不停截", .other, .folder, false, .passThrough),
    ("焦点在别处且预览开着也不管", .other, .file, true, .passThrough),
    ("结果列表没有选中项", .results, .none, false, .passThrough),
    ("没选中但预览开着 → 关掉", .results, .none, true, .closePreview),
    ("选中文件 → 弹预览", .results, .file, false, .preview),
    ("选中文件夹 → 展开浏览", .results, .folder, false, .enterFolder),
    ("预览开着再按空格 → 关掉", .results, .file, true, .closePreview),
    ("预览着文件夹时按空格 → 先关掉", .results, .folder, true, .closePreview),
]
for item in intentCases {
    let actual = SpaceRules.intent(focus: item.focus, selection: item.selection, isPreviewing: item.previewing)
    expect(actual == item.expected,
           "空格判定：\(item.name)",
           detail: "焦点 \(describe(item.focus))、\(describe(item.selection))、预览 \(item.previewing ? "开着" : "关着") → 得到 \(describe(actual))，期望 \(describe(item.expected))")
}
"""#

let driverAssertions4 = #"""
// MARK: - 7. 与表格列对齐

let windowSource = (try? String(contentsOfFile: repoRootPath + "/Lokii/Lokii/SearchWindow.swift",
                                encoding: .utf8)) ?? ""
let folderSource = (try? String(contentsOfFile: repoRootPath + "/Lokii/Lokii/FolderBrowse.swift",
                                encoding: .utf8)) ?? ""
expect(!windowSource.isEmpty, "读得到 SearchWindow.swift")
expect(!folderSource.isEmpty, "读得到 FolderBrowse.swift")

let tableKeys = Set(capture("NSSortDescriptor\\(key: \"([a-z]+)\"", in: windowSource))
let browseKeys = Set(
    capture("enum BrowseSortKey: String \\{\\s*case ([A-Za-z, ]+)", in: folderSource)
        .flatMap { $0.components(separatedBy: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
)
expect(!tableKeys.isEmpty,
       "能从 SearchWindow 里认出表格列的排序键",
       detail: "认出 \(describe(tableKeys.sorted()))")
expect(browseKeys == tableKeys,
       "BrowseSortKey 与表格列的排序键一一对应（对不上会静默退回按名称排）",
       detail: "表格 \(describe(tableKeys.sorted()))，BrowseSortKey \(describe(browseKeys.sorted()))")

// MARK: - 结果

if failures.isEmpty {
    print("✅ space_preview_browse: \(checks) 项断言通过")
    exit(0)
}
print("❌ space_preview_browse: \(failures.count)/\(checks) 项断言失败")
for failure in failures {
    print("   - \(failure)")
}
exit(1)
"""#

// MARK: - 宿主脚本：拼源码 → 编译 → 运行

struct HostCommandResult {
    let status: Int32
    let out: String
    let err: String
}

func runCapturing(_ executable: String, _ arguments: [String]) -> HostCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return HostCommandResult(status: -1, out: "", err: "无法执行 \(executable): \(error)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HostCommandResult(status: process.terminationStatus,
                             out: String(decoding: outData, as: UTF8.self),
                             err: String(decoding: errData, as: UTF8.self))
}

func main() -> Int32 {
    guard let production = try? String(contentsOf: productionFile, encoding: .utf8) else {
        FileHandle.standardError.write(Data("找不到生产代码: \(productionFile.path)\n".utf8))
        return 2
    }

    let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lokii-browse-\(UUID().uuidString)")
    let mainURL = workDir.appendingPathComponent("main.swift")
    let binaryURL = workDir.appendingPathComponent("space_preview_browse")

    do {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // 断言里要按仓库根目录去读 SearchWindow.swift，这里把路径种进去
        let seededDriver = driverSource.replacingOccurrences(of: "__REPO_ROOT__", with: repoRoot.path)
        let combined = production + "\n"
            + seededDriver + driverAssertions + driverAssertions2
            + driverAssertions3 + driverAssertions4
        try combined.write(to: mainURL, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("准备工作目录失败: \(error)\n".utf8))
        return 2
    }
    defer { try? FileManager.default.removeItem(at: workDir) }

    // 优先用 CLT 自带的 swiftc，找不到再退回 xcrun
    let swiftc = FileManager.default.isExecutableFile(atPath: "/usr/bin/swiftc")
        ? (executable: "/usr/bin/swiftc", prefix: [String]())
        : (executable: "/usr/bin/xcrun", prefix: ["swiftc"])

    let compile = runCapturing(swiftc.executable, swiftc.prefix + [mainURL.path, "-o", binaryURL.path])
    guard compile.status == 0 else {
        FileHandle.standardError.write(Data("生产代码编译失败:\n\(compile.err)\n".utf8))
        return 2
    }

    let test = runCapturing(binaryURL.path, [])
    FileHandle.standardOutput.write(Data(test.out.utf8))
    FileHandle.standardError.write(Data(test.err.utf8))
    return test.status
}

exit(main())




