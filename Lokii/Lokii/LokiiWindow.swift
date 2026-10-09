import AppKit

/// 搜索窗口。除了 AppKit 默认行为，这里承担快捷键分发：
/// Escape 收起窗口、Return 打开选中项（走 `keyDown`），
/// 以及在 `sendEvent(_:)` 里提前截获的三个组合键——
///
///   ⌘↩  把选中项交给 LaunchBar 继续挑动作
///   ⇧↩  把选中项交给 Keyboard Maestro 宏
///   ⌘F  把焦点送回搜索框
///
/// 为什么放在 `sendEvent` 而不是 `keyDown`：搜索框获得焦点时，它的 field editor
/// 会先吃掉按键（Tab、方向键等），`keyDown` 根本轮不到窗口；而 `NSApplication`
/// 只会把「没有命中主菜单」的按键事件交给窗口，所以在这里判断既不会被主菜单抢走，
/// 也不会漏掉 field editor 的情况。只处理这三个组合键，其余按键（含 ⌘C）一律
/// 交给 AppKit 正常分发，搜索框里的文本编辑行为不受影响。
final class LokiiWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    /// 三个组合键的处理闭包：返回 `true` 表示事件已消费、不再继续分发；
    /// 返回 `false` 则退回 AppKit 默认行为。
    var onCommandReturn: (() -> Bool)?
    var onShiftReturn: (() -> Bool)?
    var onCommandF: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleShortcut(event) { return }
        super.sendEvent(event)
    }

    /// 只认「恰好按下所列修饰键」的组合（caps lock 之类非交互修饰键不计入），
    /// 避免把 ⌘⌥↩ 这类用户自定义组合也一并吃掉。
    private func matches(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        let interactive: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        return event.modifierFlags.intersection(interactive) == modifiers
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 36: // Return
            if matches(event, modifiers: .command) { return onCommandReturn?() ?? false }
            if matches(event, modifiers: .shift) { return onShiftReturn?() ?? false }
            return false
        default:
            // 字母键按字符判断，兼容 Dvorak 等非 QWERTY 布局
            guard event.charactersIgnoringModifiers?.lowercased() == "f",
                  matches(event, modifiers: .command) else { return false }
            return onCommandF?() ?? false
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
