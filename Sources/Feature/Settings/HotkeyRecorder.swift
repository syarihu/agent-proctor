import AppKit
import HotkeyBridge
import Model
import Resources
import SwiftUI

/// ホットキーを打鍵で決める欄。
///
/// 押すと待ち受けに入り、次に叩いた組み合わせがそのまま入る。
/// キーの名前を仮想キーコードから引き直さず、打鍵から取った文字をそのまま覚えるのは、
/// どの文字が出るかがキーボード配列で変わるため。
struct HotkeyRecorder: View {
    @Binding var combo: HotkeyCombo?
    /// 登録に失敗したとき (他アプリが同じキーを持っているとき) に出す但し書き
    let conflicted: Bool

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                // 等幅にしない。⌘ や ⇧ は字送りが文字と同じ幅に詰められると潰れる。
                // macOS 自身がメニューのキー表示に使っているのもシステムフォント
                Text(caption)
                    .font(.system(size: 13))
                    .frame(minWidth: 78)
            }
            .help(Localized.text("app.settings.hotkey.help"))

            Button {
                stopRecording()
                combo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(combo == nil)
            .help(Localized.text("app.settings.hotkey.clear"))

            if conflicted, !recording {
                Text(Localized.text("app.settings.hotkey.taken"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        // 設定画面を閉じるときに待ち受けが残ると、他所の打鍵まで拾い続ける
        .onDisappear(perform: stopRecording)
    }

    private var caption: String {
        if recording { return Localized.text("app.settings.hotkey.recording") }
        return combo?.displayText ?? Localized.text("app.settings.hotkey.none")
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recording = true
        // ローカル監視で足りる。待ち受けているあいだ設定画面は必ず手前にいるので、
        // 全アプリの打鍵を読めるグローバル監視 (と、そのための許可) は要らない
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape は取り消し。ホットキーそのものに使えなくなるが、
            // 待ち受けから抜ける道が無いほうが困る
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let modifiers = HotkeyModifiers(event: event.modifierFlags)
            // 修飾キーが足りない打鍵は捨てて、待ち受けを続ける。
            // 弾いたことは欄が待ち受けのままであることで伝わる
            guard modifiers.hasNonShift else { return nil }
            combo = HotkeyCombo(keyCode: event.keyCode,
                                modifiers: modifiers,
                                label: Self.label(for: event))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 欄に出すキーの名前。
    ///
    /// 文字が出ないキーは `charactersIgnoringModifiers` が制御文字を返すので、
    /// そこだけ名前を当てる。残りは打鍵の文字を大文字にして使う
    private static func label(for event: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[event.keyCode] { return name }
        let typed = event.charactersIgnoringModifiers ?? ""
        if let first = typed.first, first.isLetter || first.isNumber || first.isPunctuation
            || first.isSymbol {
            return typed.uppercased()
        }
        return "#\(event.keyCode)"
    }
}
