import AppKit

/// 搜索窗口。除了 AppKit 默认行为，这里承担快捷键分发：
/// Escape 收起窗口、Return 打开选中项（走 `keyDown`），
/// 以及在 `sendEvent(_:)` 里提前截获的这几类按键——
///
///   ⌘↩      把选中项交给 LaunchBar 继续挑动作
///   ⇧↩      把选中项交给 Keyboard Maestro 宏
///   ⌘F      把焦点送回搜索框
///   ⌘1…⌘9   快速选中第 N 个结果
///   ↓ / ↑   搜索框与结果列表之间的焦点接力（是否消费由闭包按当前焦点状态决定）
///
/// 判定时忽略会残留的 ⌥（见 `ignorableModifiers`）：全局热键 ⌥⌘Space 用过后，系统
/// 修饰状态里可能残留一个「按着没松」的 ⌥，此时按 ⌘2 送到窗口的其实是 ⌘⌥2、按 ↓
/// 送到的是 ⌥↓；若严格按「恰好 ⌘」判定，这些快捷键会集体失配、落到 AppKit 并发出
/// 系统提示音，表现就是「快捷键没反应、只听到 beep」。
///
/// 为什么放在 `sendEvent` 而不是 `keyDown`：搜索框获得焦点时，它的 field editor
/// 会先吃掉按键（Tab、方向键等），`keyDown` 根本轮不到窗口；而 `NSApplication`
/// 只会把「没有命中主菜单」的按键事件交给窗口，所以在这里判断既不会被主菜单抢走，
/// 也不会漏掉 field editor 的情况。按键到意图的映射由 `shortcut(for:)` 单独给出，
/// 没有命中映射、或闭包返回 `false` 的按键（含 ⌘C）一律交回 AppKit 正常分发，
/// 搜索框里的文本编辑与列表的默认导航行为都不受影响。
final class LokiiWindow: NSWindow {
    /// 窗口关心的快捷键。
    enum Shortcut: Equatable {
        case commandReturn       // ⌘↩
        case shiftReturn         // ⇧↩
        case commandF            // ⌘F
        case selectResult(Int)   // ⌘1…⌘9，序号从 1 起算
        case moveDown            // ↓
        case moveUp              // ↑
    }

    /// 参与判定的修饰键：caps lock 之类非交互修饰键不计入。
    static let interactiveModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
    /// 匹配时视作无关的修饰键。
    ///
    /// 应用的全局热键是 ⌥⌘Space，Carbon 注册的热键会吞掉 ⌥ 的抬起事件：热键用过之后，
    /// 系统修饰状态里会残留一个「按着没松」的 ⌥，此后每个按键事件都多带 ⌥。本窗口的
    /// 快捷键都不与 ⌥ 组合（⌘↩ / ⇧↩ / ⌘F / ⌘1…⌘9 / ↓ / ↑），把 ⌥ 当作无关修饰键，
    /// 既让 ⌘⌥2 等同于 ⌘2，也顺手修好 ⌥↓、⌥⇧↩ 这类被残留 ⌥ 污染的按键。
    /// ⇧ 与 ⌃ 不在忽略之列——它们用来区分不同组合（⌘↩ 与 ⇧↩、⌘F 与 ⌘⇧F）。
    static let ignorableModifiers: NSEvent.ModifierFlags = [.option]
    /// ⌘1…⌘9 快速选中：一位数字键最多覆盖前 9 个结果。
    static let quickSelectRange = 1...9

    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    /// 组合键的处理闭包：返回 `true` 表示事件已消费、不再继续分发；
    /// 返回 `false` 则退回 AppKit 默认行为。
    var onCommandReturn: (() -> Bool)?
    var onShiftReturn: (() -> Bool)?
    var onCommandF: (() -> Bool)?
    /// ⌘1…⌘9：参数是 1 起算的结果序号。
    var onSelectResult: ((Int) -> Bool)?
    /// ↓：焦点在搜索框且光标已在文本末尾时触发。
    var onMoveDownFromSearchField: (() -> Bool)?
    /// ↑：焦点在结果列表且停在第一个结果上时触发。
    var onMoveUpFromResults: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleShortcut(event) { return }
        super.sendEvent(event)
    }

    /// 真正参与匹配的修饰键：滤掉非交互修饰键（caps lock 等）与可忽略的 ⌥。
    static func matchingModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(interactiveModifiers).subtracting(ignorableModifiers)
    }

    /// 把一次 keyDown 事件翻译成窗口关心的快捷键；返回 `nil` 表示不拦截。
    ///
    /// 只认「恰好按下所列修饰键」的组合（caps lock 之类非交互修饰键不计入，
    /// 会残留的 ⌥ 也不计入），避免把 ⌘⇧F、⌃⇧↩ 这类用户自定义组合也一并吃掉。
    /// 字符键按 `charactersIgnoringModifiers` 判断，兼容 Dvorak 等非 QWERTY 布局。
    static func shortcut(for event: NSEvent) -> Shortcut? {
        let modifiers = matchingModifiers(of: event)

        switch Int(event.keyCode) {
        case 36: // Return
            if modifiers == .command { return .commandReturn }
            if modifiers == .shift { return .shiftReturn }
            return nil
        case 125: // ↓
            return modifiers.isEmpty ? .moveDown : nil
        case 126: // ↑
            return modifiers.isEmpty ? .moveUp : nil
        default:
            guard modifiers == .command,
                  let characters = event.charactersIgnoringModifiers?.lowercased() else { return nil }
            if characters == "f" { return .commandF }
            guard let index = Int(characters), quickSelectRange.contains(index) else { return nil }
            return .selectResult(index)
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        switch Self.shortcut(for: event) {
        case .commandReturn: return onCommandReturn?() ?? false
        case .shiftReturn: return onShiftReturn?() ?? false
        case .commandF: return onCommandF?() ?? false
        case .selectResult(let index): return onSelectResult?(index) ?? false
        case .moveDown: return onMoveDownFromSearchField?() ?? false
        case .moveUp: return onMoveUpFromResults?() ?? false
        case nil: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            onEscape?()
        case 36: // Return
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
