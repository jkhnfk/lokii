import AppKit
import Foundation

/// 把选中项交给 Keyboard Maestro 里的宏继续处理（⇧↩ 或右键菜单）。
///
/// 交接走 Keyboard Maestro Engine 暴露的 AppleScript 接口：
///
///  1. `do script "<宏 UUID>" with parameter "<路径>"`——KM 官方的「带参数触发宏」
///     入口，宏里用 `%TriggerValue%` 取到这个路径。这里传 UUID 而不是宏名，
///     以后在 KM 里改宏名也不会失效。
///  2. 同时把路径写进 KM 变量 `LokiiPath`（首个路径）与 `LokiiPaths`（全部路径，
///     换行分隔），宏里可以直接用 `%Variable%LokiiPath%`，省掉自己拆参数。
///
/// 整个脚本里唯一会被插值的用户数据就是路径，插入前一律经 `appleScriptLiteral`
/// 转成 AppleScript 字符串字面量：反斜杠、双引号、换行、制表符都在转义之列，
/// 所以含空格 / 中文 / 引号 / 换行的路径都不会破坏脚本语法。
/// 改动本文件请连带跑 `tests/keyboard_maestro_handoff.swift` 里的回归。
enum KeyboardMaestro {

    /// Keyboard Maestro Engine 的 bundle id（`Keyboard Maestro.app` 内嵌的引擎 App）。
    static let engineBundleIdentifier = "com.stairways.keyboardmaestro.engine"

    /// ⇧↩ 触发的宏（由「传入路径」的宏负责后续处理）。
    static let handoffMacroUUID = "7C10C974-B30F-441B-A5C6-A43FC8BF48E2"

    /// 写入 KM 变量时用的名字，宏里以 `%Variable%LokiiPath%` 引用。
    static let pathVariableName = "LokiiPath"
    static let pathsVariableName = "LokiiPaths"

    /// AppleScript 报错编号：事件未获授权（系统设置里「自动化」权限被拒）。
    private static let notAuthorizedErrorNumber = -1743

    enum HandoffError: LocalizedError {
        case notInstalled
        case notAuthorized
        case macroFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return L("search.keyboardMaestro.notInstalled")
            case .notAuthorized:
                return L("search.keyboardMaestro.notAuthorized")
            case .macroFailed(let message):
                return message.isEmpty ? L("search.keyboardMaestro.failed") : message
            }
        }
    }

    /// Keyboard Maestro 是否已安装。
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: engineBundleIdentifier) != nil
    }

    /// 触发交接宏。返回宏里 `Return` 动作回传的值（宏没有返回值时为 `nil`）。
    ///
    /// 同步执行：KM 的 `do script` 要等宏跑完才返回，宏里若含等待或交互动作会
    /// 阻塞调用线程，所以调用方把它放到主线程之外执行。
    @discardableResult
    static func handoff(paths: [URL]) throws -> String? {
        guard !paths.isEmpty else { return nil }
        guard isInstalled else { throw HandoffError.notInstalled }

        var error: NSDictionary?
        let result = NSAppleScript(source: source(paths: paths.map(\.path)))?
            .executeAndReturnError(&error)

        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == notAuthorizedErrorNumber { throw HandoffError.notAuthorized }
            let message = (error[NSAppleScript.errorMessage] as? String)
                ?? (error[NSAppleScript.errorBriefMessage] as? String)
                ?? ""
            throw HandoffError.macroFailed(message)
        }

        let returned = result?.stringValue
        return (returned?.isEmpty ?? true) ? nil : returned
    }

    /// 生成交给 Keyboard Maestro Engine 的 AppleScript 源码。
    ///
    /// 单独拆出来是为了能在命令行里用 `osacompile`（只编译、不发 Apple 事件）
    /// 和 `osascript` 做回归验证，见 `tests/keyboard_maestro_handoff.swift`。
    static func source(paths: [String]) -> String {
        let first = paths.first ?? ""
        let joined = paths.joined(separator: "\n")
        return """
        set lokiiPathValue to \(appleScriptLiteral(first))
        set lokiiPathsValue to \(appleScriptLiteral(joined))
        tell application "Keyboard Maestro Engine"
            -- 变量写入失败（例如未授予自动化权限）不影响下面真正触发宏
            try
                setvariable "\(pathVariableName)" to lokiiPathValue
                setvariable "\(pathsVariableName)" to lokiiPathsValue
            end try
            do script "\(handoffMacroUUID)" with parameter lokiiPathValue
        end tell
        """
    }

    /// 把任意字符串转成 AppleScript 字符串字面量（含两侧引号）。
    ///
    /// AppleScript 字面量里只有 `\` 和 `"` 是元字符，但裸换行会把脚本切成多行、
    /// 直接语法错误，所以 `\n` `\r` `\t` 一并转义；其余控制字符（文件名里几乎不
    /// 可能出现）改成 `" & (ASCII character N) & "` 拼接，避免把不可见字符写进源码。
    static func appleScriptLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"   // backslash
            case 0x22: out += "\\\""   // double quote
            case 0x0A: out += "\\n"    // line feed
            case 0x0D: out += "\\r"    // carriage return
            case 0x09: out += "\\t"    // tab
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\" & (ASCII character \(scalar.value)) & \""
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
