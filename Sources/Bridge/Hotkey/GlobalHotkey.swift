import AppKit
import Carbon.HIToolbox
import Model

/// アプリが前面にいなくても効くホットキーの登録口。
///
/// Carbon の `RegisterEventHotKey` を使う。`NSEvent` のグローバル監視でも打鍵は拾えるが、
/// あちらはアクセシビリティの許可が要る。見取り図を出すためだけに、
/// 全キー入力を読める許可を求めることになるので取らない。
///
/// 押されたことは Carbon からメインスレッドのイベントループに届く。
@MainActor
public final class GlobalHotkey {
    /// いま登録されているもの。Carbon のコールバックは C の関数ポインタで、
    /// 呼び出し側の文脈を持てないので、ここを経由して本体に戻す
    private static var shared: GlobalHotkey?

    /// アプリごとの識別子。他アプリの登録と混ざらないよう自分の4文字を名乗る ('PRCT')
    private static let signature = OSType(0x5052_4354)

    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: () -> Void

    private init(action: @escaping () -> Void) {
        self.action = action
    }

    /// ホットキーを張り替える。
    ///
    /// `combo` が nil なら登録を外すだけ。押しても何も起きないキー (修飾なし・Shift だけ) は
    /// 普通の入力を奪ってしまうので、ここで断る。
    /// - Returns: 登録できたかどうか。他アプリが同じキーを取っていると false になる
    @discardableResult
    public static func set(_ combo: HotkeyCombo?, action: @escaping () -> Void) -> Bool {
        let center = shared ?? GlobalHotkey(action: action)
        shared = center
        center.action = action
        center.unregister()

        guard let combo, combo.isRegistrable else { return combo == nil }
        return center.register(combo)
    }

    /// 登録を外す。設定で空にしたときと、アプリを畳むときに通る
    public static func clear() {
        shared?.unregister()
    }

    private func register(_ combo: HotkeyCombo) -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // ハンドラは1度だけ入れる。張り替えのたびに足すと、
        // 1回の打鍵で登録した回数ぶん発火するようになる
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { GlobalHotkey.shared?.action() }
                return noErr
            }, 1, &eventType, nil, &handler)
        }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode),
                                         Self.carbonModifiers(combo.modifiers),
                                         id, GetApplicationEventTarget(), 0, &hotkey)
        if status != noErr {
            hotkey = nil
            return false
        }
        return true
    }

    private func unregister() {
        guard let hotkey else { return }
        UnregisterEventHotKey(hotkey)
        self.hotkey = nil
    }

    /// Carbon の修飾キーのビット。AppKit とも自前の表現とも値が違う
    private static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }
}

public extension HotkeyModifiers {
    /// 打鍵から修飾キーを取る。
    ///
    /// `deviceIndependentFlagsMask` で絞るのは、CapsLock や左右の別といった、
    /// ホットキーの一致判定に関係しないビットを落とすため
    init(event flags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        if masked.contains(.control) { modifiers.insert(.control) }
        if masked.contains(.option) { modifiers.insert(.option) }
        if masked.contains(.shift) { modifiers.insert(.shift) }
        if masked.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
