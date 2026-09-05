import AppKit
import CoreGraphics
import ItermBridge

/// サイドバー表示領域を確保するため、iTerm2 ウィンドウの位置とサイズを調整するクラス。
///
/// ウィンドウが画面左端にある場合、サイドバーが重なるのを防ぐため、
/// iTerm2 ウィンドウの左端のみを右方向へ移動して幅を縮小する（右端の位置は維持）。
/// 対象は以下のいずれかに該当するウィンドウに限定する:
/// - 画面左端に配置されているウィンドウ（最大化または左寄せ）
/// - 本クラスによって移動済みのウィンドウ（移動後の位置を維持しているもの）
///
/// サイドバー非表示時または終了時には元の位置・幅に復元する。
/// ただしユーザーが手動でウィンドウを移動・リサイズしていた場合は上書き復元を行わない。
///
/// ウィンドウ枠の取得は CGWindowList（権限不要）、リサイズは AppleScript（要オートメーション権限）を使用する。
/// 権限がない場合はウィンドウ移動をスキップする。
@MainActor
final class SidebarRoom {
    /// 視認性を保つための iTerm2 ウィンドウ最小幅
    private let minimumTerminalWidth: CGFloat = 320
    /// 追従ループ（高頻度）での過剰な Apple Event 送信を抑止するためのクールダウン時間（秒）
    private let cooldown: TimeInterval = 0.5
    /// iTerm2 のセル単位丸め誤差を吸収するための許容ピクセル差
    private let tolerance: CGFloat = 12
    /// CGWindowList の反映遅延による誤判定（リサイズ失敗とみなすこと）を防ぐ猶予時間（秒）
    private let staleGrace: TimeInterval = 2
    /// ウィンドウマネージャ等による位置復元ループを検出・離脱するための試行回数上限
    private let undoLimit = 3
    /// 連続復元ループ検出時のバックオフ時間（秒）
    private let backoff: TimeInterval = 30

    /// 最後に移動させたウィンドウの記録（移動前の左端X座標、適用後の左端X座標）
    private var nudged: (original: CGFloat, applied: CGFloat)?
    private var lastAttempt = Date.distantPast

    /// 同一ウィンドウ枠へのリサイズ要求履歴（対象矩形と試行回数）。リサイズ不可のウィンドウへの無駄な要求を抑止
    private var requested: (bounds: CGRect, count: Int)?

    /// 移動前のウィンドウ枠および元に戻された回数（外部ウィンドウマネージャとの競合検出用）
    private var beforeNudge: CGRect?
    private var undoCount = 0
    private var backoffUntil = Date.distantPast

    /// 左端に余裕がない場合に iTerm2 ウィンドウを右へ寄せる。
    ///
    /// - Parameters:
    ///   - bounds: iTerm2 ウィンドウ矩形（CGWindowList の左上原点）
    ///   - screen: ウィンドウが存在する画面
    ///   - width: サイドバー幅
    /// - Returns: ウィンドウを移動させた場合は true
    @discardableResult
    func makeRoom(itermBounds bounds: CGRect, screen: NSScreen, width: CGFloat) -> Bool {
        // Dock やメニューバーを除いた可視領域の左端を基準とする
        let leftLimit = screen.visibleFrame.minX
        let wanted = leftLimit + width

        // macOS ネイティブのフルスクリーン表示中はウィンドウサイズ変更不可のため除外
        guard !isNativeFullScreen(bounds, screen: screen) else { return false }

        // 画面左端にあるか、または過去に本クラスで配置した位置にあるウィンドウのみを対象とする
        let isOurs = nudged.map { abs(bounds.minX - $0.applied) < tolerance } ?? false
        guard bounds.minX <= leftLimit + 2 || isOurs else { return false }
        // 右方向への移動（縮小）のみを許可し、左方向への自動拡大は行わない（ユーザーの意図しない幅変更を防止）
        guard bounds.minX < wanted - 1 else { return false }
        guard bounds.maxX - wanted >= minimumTerminalWidth else { return false }

        // バックオフ期間中は移動を抑止
        guard Date() >= backoffUntil else { return false }
        if undoCount >= undoLimit { undoCount = 0 }

        guard Date().timeIntervalSince(lastAttempt) >= cooldown else { return false }

        // 同一枠に対してリサイズが反映されない場合の試行回数制限（反映遅延猶予時間を考慮）
        if let requested, SidebarRoom.isSame(requested.bounds, bounds) {
            guard Date().timeIntervalSince(lastAttempt) >= staleGrace else { return false }
            guard requested.count < 2 else { return false }
            self.requested = (bounds, requested.count + 1)
        } else {
            requested = (bounds, 1)
        }
        lastAttempt = Date()

        // 以前の移動直前の枠に戻されている場合は外部復元（ウィンドウマネージャ等）と判定
        if let beforeNudge, SidebarRoom.isSame(beforeNudge, bounds) {
            undoCount += 1
        } else {
            undoCount = 0
        }
        if undoCount >= undoLimit {
            backoffUntil = Date().addingTimeInterval(backoff)
            return false
        }

        // 過去に移動済みのウィンドウであれば初回移動前の左端座標を引き継ぐ
        let original = isOurs ? (nudged?.original ?? bounds.minX) : bounds.minX

        let target = CGRect(x: wanted, y: bounds.minY,
                            width: bounds.maxX - wanted, height: bounds.height)
        guard ItermBridge.setCurrentWindowBounds(target) else { return false }
        beforeNudge = bounds
        nudged = (original: original, applied: wanted)
        return true
    }

    /// 寄せた分を戻す。サイドバーが引っ込むときと、アプリを終えるときに呼ぶ。
    func restore() {
        requested = nil
        beforeNudge = nil
        undoCount = 0
        backoffUntil = .distantPast
        guard let nudged else { return }
        self.nudged = nil

        // いまの枠を読んでから決める。人が動かしたあとなら触らない
        guard let bounds = SidebarRoom.currentItermBounds(),
              abs(bounds.minX - nudged.applied) < tolerance else { return }
        ItermBridge.setCurrentWindowBounds(
            CGRect(x: nudged.original, y: bounds.minY,
                   width: bounds.maxX - nudged.original, height: bounds.height))
    }

    /// リトライ状態をリセットする。サイドバー幅の変更時などに呼び出す。
    /// バックオフと試行回数を初期化しつつ、元のサイズへの復元先を保持するため移動履歴は残す。
    func retryNow() {
        requested = nil
        undoCount = 0
        backoffUntil = .distantPast
    }

    /// 保持している移動履歴を破棄する。iTerm2 プロセス終了時などに使用する。
    /// 仮想デスクトップ切り替えや最小化など一時的な非表示では復元先を失わないよう呼び出さない。
    func forget() {
        nudged = nil
        requested = nil
        beforeNudge = nil
        undoCount = 0
        backoffUntil = .distantPast
    }

    // MARK: -

    /// メニューバー領域を含めて画面全体を覆っているかにより macOS ネイティブフルスクリーンかを判定する
    private func isNativeFullScreen(_ bounds: CGRect, screen: NSScreen) -> Bool {
        bounds.height >= screen.frame.height - 1
    }

    /// 2つの矩形が丸め誤差の範囲内で同一かを判定
    private static func isSame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    /// ウィンドウ矩形と最大の重なりを持つ画面を取得する。
    /// マルチディスプレイ環境において対象ウィンドウが存在する画面の visibleFrame を正しく基準にするために使用する。
    static func screen(containing bounds: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            // 重なりがない場合は空の矩形（面積 0）となる
            let overlap = cgFrame(of: screen).intersection(bounds)
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// NSScreen の矩形を CGWindowList と同様の座標系（メイン画面左上原点、下向きY軸）に変換する。
    /// 原点がメイン画面にあるため、変換には常にメイン画面の高さを使用する。
    private static func cgFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        return CGRect(x: screen.frame.minX,
                      y: primary.frame.height - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    /// CGWindowList から最前面の iTerm2 ウィンドウ矩形を取得する
    static func currentItermBounds() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for window in list {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            guard owner == "iTerm2", layer == 0,
                  let box = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let width = box["Width"] ?? 0
            let height = box["Height"] ?? 0
            if width >= 400 && height >= 300 {
                return CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0,
                              width: width, height: height)
            }
        }
        return nil
    }
}
