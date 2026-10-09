#!/usr/bin/env swift
// ==============================================================================
// keyboard_maestro_handoff —— `Lokii/Lokii/KeyboardMaestro.swift` 的回归测试
//
// 用法（在仓库根目录下执行）:
//   swift tests/keyboard_maestro_handoff.swift
//
// 为什么长这样：被测类型在 app target 里，脚本没法直接 import，所以这里把生产
// 源码 `KeyboardMaestro.swift` 原样读进来，补一个 `L(...)` 的语言包桩，再拼上
// 下面的断言，生成一个临时 `main.swift` 用 swiftc 编出来执行。断言跑的就是
// 生产实现本体，不存在「测试里另抄一份实现」的漂移。
//
// 覆盖范围：
//   1. `appleScriptLiteral` 的转义（引号、反斜杠、换行、回车、制表符、控制字符）
//   2. 这些字面量经 `osascript` 真实解析后读回，必须与原值逐字节一致
//   3. `source(paths:)` 的输出能通过 `osacompile`（语法有效），
//      且确实带上了宏 UUID 与两个 KM 变量名
//
// 不需要安装 Keyboard Maestro，测试过程也不会发出任何 Apple 事件。
// ==============================================================================

import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/
    .deletingLastPathComponent()   // 仓库根目录

let productionFile = repoRoot.appendingPathComponent("Lokii/Lokii/KeyboardMaestro.swift")

// MARK: - 测试驱动（编译进临时可执行文件，与生产代码同一个模块）

let driverSource = #"""
// ---- 本段由 tests/keyboard_maestro_handoff.swift 生成 ----

/// 生产代码里 `L(...)` 的语言包桩：断言只比对键名与返回值，不依赖真实文案。
func L(_ key: String, comment: String = "") -> String { key }

var checks = 0
var failures: [String] = []

/// 把字符串转成便于阅读的转义形式，只在断言失败时用于打印。
func describe(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x5C: out += "\\\\"
        case 0x22: out += "\\\""
        default: out += String(scalar)
        }
    }
    return out + "\""
}

func expect(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
    checks += 1
    guard !condition else { return }
    let extra = detail()
    failures.append(extra.isEmpty ? label : "\(label) — \(extra)")
}

func expectEqual(_ actual: String, _ expected: String, _ label: String) {
    checks += 1
    guard actual != expected else { return }
    failures.append("\(label) — 得到 \(describe(actual))，期望 \(describe(expected))")
}

struct CommandResult {
    let status: Int32
    let out: String
    let err: String
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) -> CommandResult {
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
        return CommandResult(status: -1, out: "", err: "无法执行 \(executable): \(error)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
}
"""#

// 驱动剩下的部分。分成两段只是为了不让单个字符串太长，最终会拼在一起。
let driverAssertions = #"""
// MARK: - 1. appleScriptLiteral 的转义

let cases: [(name: String, value: String, literal: String)] = [
    ("纯 ASCII 路径", "/Users/me/Notes.txt", "\"/Users/me/Notes.txt\""),
    ("空格与中文", "/Users/me/我的 笔记.txt", "\"/Users/me/我的 笔记.txt\""),
    ("双引号", "/tmp/say \"hi\".txt", "\"/tmp/say \\\"hi\\\".txt\""),
    ("反斜杠", "/tmp/back\\slash.txt", "\"/tmp/back\\\\slash.txt\""),
    ("换行", "/tmp/line1\nline2.txt", "\"/tmp/line1\\nline2.txt\""),
    ("回车", "/tmp/cr\rhere.txt", "\"/tmp/cr\\rhere.txt\""),
    ("制表符", "/tmp/tab\there.txt", "\"/tmp/tab\\there.txt\""),
    ("控制字符 (BEL)", "/tmp/bell\u{07}.txt", "\"/tmp/bell\" & (ASCII character 7) & \".txt\""),
]

for item in cases {
    expectEqual(KeyboardMaestro.appleScriptLiteral(item.value), item.literal,
                "appleScriptLiteral(\(item.name))")
}

// MARK: - 2. 经 AppleScript 解析器往返

for item in cases {
    let parsed = run("/usr/bin/osascript", ["-e", "return " + item.literal])
    guard parsed.status == 0 else {
        expect(false, "osascript 解析 \(item.name)",
               detail: parsed.err.trimmingCharacters(in: .whitespacesAndNewlines))
        continue
    }
    // osascript 会在结果末尾补一个换行，去掉它再逐字节比对
    var returned = parsed.out
    if returned.hasSuffix("\n") { returned.removeLast() }
    expectEqual(returned, item.value, "osascript 往返(\(item.name))")
}

// MARK: - 3. source(paths:) 的内容与语法

let paths = ["/Users/me/我的 笔记.txt", "/tmp/say \"hi\".txt"]
let script = KeyboardMaestro.source(paths: paths)

expect(script.contains("\"\(KeyboardMaestro.handoffMacroUUID)\""), "源码带上了宏 UUID")
expect(script.contains("setvariable \"\(KeyboardMaestro.pathVariableName)\""), "源码写入 LokiiPath")
expect(script.contains("setvariable \"\(KeyboardMaestro.pathsVariableName)\""), "源码写入 LokiiPaths")
expect(script.contains(KeyboardMaestro.appleScriptLiteral(paths[0])), "源码用字面量传首个路径")
expect(script.contains(KeyboardMaestro.appleScriptLiteral(paths.joined(separator: "\n"))),
       "源码用字面量传全部路径")

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("lokii-km-handoff-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
let scriptURL = workDir.appendingPathComponent("handoff.applescript")
let compiledURL = workDir.appendingPathComponent("handoff.scpt")
try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
let compiled = run("/usr/bin/osacompile", ["-o", compiledURL.path, scriptURL.path])
expect(compiled.status == 0, "osacompile 编译 source(paths:)",
       detail: compiled.err.trimmingCharacters(in: .whitespacesAndNewlines))
try? FileManager.default.removeItem(at: workDir)

// MARK: - 结果

if failures.isEmpty {
    print("✅ keyboard_maestro_handoff: \(checks) 项断言通过")
    exit(0)
}
print("❌ keyboard_maestro_handoff: \(failures.count)/\(checks) 项断言失败")
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
        .appendingPathComponent("lokii-km-handoff-\(UUID().uuidString)")
    let mainURL = workDir.appendingPathComponent("main.swift")
    let binaryURL = workDir.appendingPathComponent("keyboard_maestro_handoff")

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
