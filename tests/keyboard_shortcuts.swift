#!/usr/bin/env swift
// ==============================================================================
// keyboard_shortcuts —— `Lokii/Lokii/LokiiWindow.swift` 的快捷键回归测试
//
// 用法（在仓库根目录下执行）:
//   swift tests/keyboard_shortcuts.swift
//
// 为什么长这样：被测类型在 app target 里，脚本没法直接 import，所以这里把生产
// 源码 `LokiiWindow.swift` 原样读进来，拼上下面的断言，生成一个临时 `main.swift`
// 用 swiftc 编出来执行。断言跑的就是生产实现本体，不存在「测试里另抄一份实现」的漂移。
//
// 覆盖范围：
//   1. `LokiiWindow.shortcut(for:)` 的「事件 → 意图」映射：⌘↩ / ⇧↩ / ⌘F /
//      ⌘1…⌘9 / ↓ / ↑ / Space / ⌘↓ / ⌘↑ 各自命中，且快速选中的序号从 1 起算
//   2. 只有「恰好这些修饰键」才拦截：⌘⇧↩、⌃⇧↩、⌘⇧F、⇧↓、⌘0、⌘C、
//      ⌘Space、⌃Space、⇧Space、⌘⇧↓/⌘⇧↑ 一律返回 nil 交回 AppKit
//   3. 会残留的 ⌥ 不影响判定：⌘⌥↩ / ⌥⇧↩ / ⌘⌥F / ⌘⌥2 / ⌥↓ / ⌥↑ / ⌥Space /
//      ⌘⌥↓ / ⌘⌥↑ 与去掉 ⌥ 的组合等价，但 ⌥ 本身不构成快捷键（⌥1 仍返回 nil）
//   4. caps lock 之类非交互修饰键不参与判定
//   5. 无修饰键的 ↓ / ↑ / Space 映射成 moveDown / moveUp / preview，是否消费交给
//      闭包按当前焦点决定；带 ⌘ 的方向键另有单独含义（⌘↓ 进文件夹、⌘↑ 回上级），
//      ⇧/⌃ 参与的方向键组合一律不拦截，不抢列表自己的多选与滚动
//   6. 无修饰键的可打印字符（a-z、0-9、标点）映射成 typeCharacter，是否消费交给
//      闭包按焦点决定；控制字符（Tab、Esc、退格）与功能键（方向键）不算，
//      ⇧/⌃/⌘ 参与的字符键也不拦截
//
// 不覆盖（依赖真实窗口与 field editor，只能手工验证）：焦点接力本身，即
// 「↓ 从搜索框跳到列表」「↑ 由首行回到搜索框末尾」「⌘1…⌘9 选中并聚焦列表」。
// 本测试不创建 NSWindow，因此在无窗口服务器的环境（CI、SSH）下也能跑。
// ==============================================================================

import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/
    .deletingLastPathComponent()   // 仓库根目录

let productionFile = repoRoot.appendingPathComponent("Lokii/Lokii/LokiiWindow.swift")

// MARK: - 测试驱动（编译进临时可执行文件，与生产代码同一个模块）

let driverSource = #"""
// ---- 本段由 tests/keyboard_shortcuts.swift 生成 ----

import AppKit

var checks = 0
var failures: [String] = []

func expect(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
    checks += 1
    guard !condition else { return }
    let extra = detail()
    failures.append(extra.isEmpty ? label : "\(label) — \(extra)")
}

/// 把映射结果转成便于阅读的文本，只在断言失败时用于打印。
func describe(_ shortcut: LokiiWindow.Shortcut?) -> String {
    guard let shortcut else { return "nil（不拦截）" }
    switch shortcut {
    case .commandReturn: return "⌘↩"
    case .shiftReturn: return "⇧↩"
    case .commandF: return "⌘F"
    case .selectResult(let index): return "⌘\(index)"
    case .moveDown: return "↓"
    case .moveUp: return "↑"
    case .commandDown: return "⌘↓"
    case .commandUp: return "⌘↑"
    case .preview: return "Space"
    case .typeCharacter(let characters): return "打字 \(characters)"
    }
}

/// 合成一次 keyDown 事件。
///
/// `keyCode` 是物理键位（方向键、回车靠它判断，与键盘布局无关）；
/// `characters` 既作 `characters` 也作 `charactersIgnoringModifiers`——
/// 按 AppKit 的约定，后者只忽略 Shift 以外的修饰键，所以 ⇧1 这类组合
/// 传进来就是 "!"，与真实事件一致。
func keyDown(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    guard let event = NSEvent.keyEvent(with: .keyDown,
                                       location: .zero,
                                       modifierFlags: modifiers,
                                       timestamp: 0,
                                       windowNumber: 0,
                                       context: nil,
                                       characters: characters,
                                       charactersIgnoringModifiers: characters,
                                       isARepeat: false,
                                       keyCode: keyCode) else {
        fatalError("无法合成 keyDown 事件: keyCode=\(keyCode) characters=\(characters)")
    }
    return event
}

// 物理键位常量（ANSI 键盘）
let returnKey: UInt16 = 36
let downArrow: UInt16 = 125
let upArrow: UInt16 = 126
let escapeKey: UInt16 = 53
let fKey: UInt16 = 3
let cKey: UInt16 = 8
let aKey: UInt16 = 0
let leftBracketKey: UInt16 = 33
let spaceKey: UInt16 = 49
let iKey: UInt16 = 34
let tabKey: UInt16 = 48
let leftArrow: UInt16 = 123
let rightArrow: UInt16 = 124
"""#
// 驱动剩下的部分。分成两段只是为了不让单个字符串太长，最终会拼在一起。
let driverAssertions = #"""
// MARK: - 事件 → 意图 映射

let cases: [(name: String, event: NSEvent, expected: LokiiWindow.Shortcut?)] = [
    // 交接与回焦：本次之前就有的三个组合键必须原样保留
    ("⌘↩ 交给 LaunchBar", keyDown(returnKey, "\r", .command), .commandReturn),
    ("⇧↩ 交给 Keyboard Maestro", keyDown(returnKey, "\r", .shift), .shiftReturn),
    ("⌘F 回到搜索框", keyDown(fKey, "f", .command), .commandF),

    // 快速选中：⌘1…⌘9，序号从 1 起算
    ("⌘1 选中第 1 个结果", keyDown(18, "1", .command), .selectResult(1)),
    ("⌘2 选中第 2 个结果", keyDown(19, "2", .command), .selectResult(2)),
    ("⌘3 选中第 3 个结果", keyDown(20, "3", .command), .selectResult(3)),
    ("⌘4 选中第 4 个结果", keyDown(21, "4", .command), .selectResult(4)),
    ("⌘5 选中第 5 个结果", keyDown(23, "5", .command), .selectResult(5)),
    ("⌘6 选中第 6 个结果", keyDown(22, "6", .command), .selectResult(6)),
    ("⌘7 选中第 7 个结果", keyDown(26, "7", .command), .selectResult(7)),
    ("⌘8 选中第 8 个结果", keyDown(28, "8", .command), .selectResult(8)),
    ("⌘9 选中第 9 个结果", keyDown(25, "9", .command), .selectResult(9)),

    // 无修饰键的方向键：交给闭包按当前焦点决定，闭包不认时才落回 AppKit
    ("↓ 从搜索框跳到列表", keyDown(downArrow, "\u{F701}", []), .moveDown),
    ("↑ 由首行回到搜索框", keyDown(upArrow, "\u{F700}", []), .moveUp),

    // 空格：Finder 式 Quick Look / 展开文件夹，同样由闭包按焦点与选中项决定
    ("Space 预览选中文件或展开文件夹", keyDown(spaceKey, " ", []), .preview),

    // 无修饰键的普通字符：列表聚焦时想输入文字筛选（是否消费由闭包按焦点决定）
    ("无修饰键 a 想打字筛选", keyDown(aKey, "a", []), .typeCharacter("a")),
    ("无修饰键 i 想打字筛选", keyDown(iKey, "i", []), .typeCharacter("i")),
    ("无修饰键 9 想打字筛选", keyDown(25, "9", []), .typeCharacter("9")),
    ("无修饰键标点 . 也想打字筛选", keyDown(47, ".", []), .typeCharacter(".")),
    ("裸 f 也想打字筛选（不是 ⌘F）", keyDown(fKey, "f", []), .typeCharacter("f")),

    // 带 ⌘ 的方向键：下钻子目录 / 回到上级目录
    ("⌘↓ 进入选中的文件夹", keyDown(downArrow, "\u{F701}", .command), .commandDown),
    ("⌘↑ 返回上一级目录", keyDown(upArrow, "\u{F700}", .command), .commandUp),

    // 非交互修饰键（caps lock）不影响判定
    ("⌘↩ + caps lock 仍命中", keyDown(returnKey, "\r", [.command, .capsLock]), .commandReturn),
    ("⌘1 + caps lock 仍命中", keyDown(18, "1", [.command, .capsLock]), .selectResult(1)),
    ("↓ + caps lock 仍命中", keyDown(downArrow, "\u{F701}", [.capsLock]), .moveDown),
    ("Space + caps lock 仍命中", keyDown(spaceKey, " ", [.capsLock]), .preview),

    // 会残留的 ⌥ 不影响判定：全局热键 ⌥⌘Space 被 Carbon 吞掉 ⌥ 抬起事件后，系统修饰
    // 状态里会留下按住的 ⌥，此后每个按键都多带它。带 ⌥ 与不带 ⌥ 必须等价，否则快捷键
    // 会集体失配、落到 AppKit 发出系统提示音。
    ("⌘⌥↩ 仍交给 LaunchBar", keyDown(returnKey, "\r", [.command, .option]), .commandReturn),
    ("⌥⇧↩ 仍交给 Keyboard Maestro", keyDown(returnKey, "\r", [.shift, .option]), .shiftReturn),
    ("⌘⌥F 仍回到搜索框", keyDown(fKey, "f", [.command, .option]), .commandF),
    ("⌘⌥1 仍选中第 1 个结果", keyDown(18, "1", [.command, .option]), .selectResult(1)),
    ("⌘⌥2 仍选中第 2 个结果", keyDown(19, "2", [.command, .option]), .selectResult(2)),
    ("⌘⌥9 仍选中第 9 个结果", keyDown(25, "9", [.command, .option]), .selectResult(9)),
    ("⌥↓ 仍从搜索框跳到列表", keyDown(downArrow, "\u{F701}", .option), .moveDown),
    ("⌥↑ 仍由首行回到搜索框", keyDown(upArrow, "\u{F700}", .option), .moveUp),
    ("⌥Space 仍是预览", keyDown(spaceKey, " ", .option), .preview),
    ("⌘⌥↓ 仍进入文件夹", keyDown(downArrow, "\u{F701}", [.command, .option]), .commandDown),
    ("⌘⌥↑ 仍返回上一级", keyDown(upArrow, "\u{F700}", [.command, .option]), .commandUp),
    ("⌘⌥1 + caps lock 仍命中", keyDown(18, "1", [.command, .option, .capsLock]), .selectResult(1)),

    // 不该被窗口吃掉的按键：返回 nil，继续走 AppKit / 主菜单
    ("裸 ↩ 交给窗口 keyDown 打开条目", keyDown(returnKey, "\r", []), nil),
    ("⌘⇧↩ 不属于窗口快捷键", keyDown(returnKey, "\r", [.command, .shift]), nil),
    ("⌃⇧↩ 不属于窗口快捷键", keyDown(returnKey, "\r", [.control, .shift]), nil),
    ("⌘⇧F 不属于窗口快捷键", keyDown(fKey, "F", [.command, .shift]), nil),
    ("⌘0 超出快速选中范围", keyDown(29, "0", .command), nil),
    ("⌘⇧1 是符号键，不参与快速选中", keyDown(18, "!", [.command, .shift]), nil),
    ("⌘⌥⇧1 也是符号键，不参与快速选中", keyDown(18, "!", [.command, .option, .shift]), nil),
    ("⌥1 没有 ⌘，仍不参与快速选中", keyDown(18, "1", .option), nil),
    ("⌃⌥1 带控制键，不参与快速选中", keyDown(18, "1", [.control, .option]), nil),
    ("⌘C 仍归主菜单（复制路径）", keyDown(cKey, "c", .command), nil),
    ("⌘A 仍归主菜单（全选）", keyDown(aKey, "a", .command), nil),
    ("⌘⇧↓ 不属于窗口快捷键", keyDown(downArrow, "\u{F701}", [.command, .shift]), nil),
    ("⇧↓ 要留给列表多选", keyDown(downArrow, "\u{F701}", .shift), nil),
    ("⌃↓ 不属于窗口快捷键", keyDown(downArrow, "\u{F701}", .control), nil),
    ("⇧↑ 要留给列表多选", keyDown(upArrow, "\u{F700}", .shift), nil),
    ("⌘⇧↑ 不属于窗口快捷键", keyDown(upArrow, "\u{F700}", [.command, .shift]), nil),
    ("⌃↑ 不属于窗口快捷键", keyDown(upArrow, "\u{F700}", .control), nil),
    ("⌘Space 是 Spotlight 的，不拦截", keyDown(spaceKey, " ", .command), nil),
    ("⌃Space 是输入法切换，不拦截", keyDown(spaceKey, " ", .control), nil),
    ("⇧Space 不拦截", keyDown(spaceKey, " ", .shift), nil),
    ("⌘⌥⇧Space 带 ⇧ 不拦截", keyDown(spaceKey, " ", [.command, .option, .shift]), nil),
    ("⇧a 是打大写，不拦截", keyDown(aKey, "A", .shift), nil),
    ("Tab 是焦点切换，不拦截", keyDown(tabKey, "\t", []), nil),
    ("左方向键不是可打印字符，不拦截", keyDown(leftArrow, "\u{F702}", []), nil),
    ("右方向键不是可打印字符，不拦截", keyDown(rightArrow, "\u{F703}", []), nil),
    ("Esc 仍走窗口 keyDown 隐藏窗口", keyDown(escapeKey, "\u{1B}", []), nil),
    ("⌘[ 是无关组合键", keyDown(leftBracketKey, "[", .command), nil),
]

for testCase in cases {
    let actual = LokiiWindow.shortcut(for: testCase.event)
    expect(actual == testCase.expected, testCase.name,
           detail: "得到 \(describe(actual))，期望 \(describe(testCase.expected))")
}

// MARK: - 快速选中范围

expect(LokiiWindow.quickSelectRange == 1...9,
       "quickSelectRange 应为 1...9（一位数字键的上限）",
       detail: "得到 \(LokiiWindow.quickSelectRange)")

// MARK: - 结果

if failures.isEmpty {
    print("✅ keyboard_shortcuts: \(checks) 项断言通过")
    exit(0)
}
print("❌ keyboard_shortcuts: \(failures.count)/\(checks) 项断言失败")
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
        .appendingPathComponent("lokii-shortcuts-\(UUID().uuidString)")
    let mainURL = workDir.appendingPathComponent("main.swift")
    let binaryURL = workDir.appendingPathComponent("keyboard_shortcuts")

    do {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let combined = production + "\n" + driverSource + driverAssertions
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
