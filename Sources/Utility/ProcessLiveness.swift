import Foundation

/// プロセスの生存確認ユーティリティ。
///
/// 端末エミュレータの種類に依存せずセッションの終了判定を行うために使用する。
/// macOS の PID 再利用による別プロセスの誤検知を防ぐため、PID だけでなくプロセスの起動時刻も照合する。
public enum ProcessLiveness {
    /// 指定 PID のプロセス起動時刻（Unix epoch 秒）を取得する。プロセスが存在しない場合は nil。
    /// 高頻度かつロック内で呼び出されるため、fork を避け sysctl でカーネルから直接情報を取得する。
    public static func startedAt(pid: Int) -> Int? {
        guard let pid = Int32(exactly: pid), pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // 存在しない PID でも sysctl 自体は 0 を返す場合があるため、返却バッファサイズで実在を確認
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // ゾンビ状態のプロセスは終了済みとして扱う
        guard info.kp_proc.p_stat != SZOMB else { return nil }
        return Int(info.kp_proc.p_starttime.tv_sec)
    }

    /// - Parameter startedAt: プロセス登録時の起動時刻。未指定時は PID の実在のみで判定する（PID 再利用の検証はスキップ）
    public static func isAlive(pid: Int, startedAt expected: Int? = nil) -> Bool {
        guard let actual = startedAt(pid: pid) else { return false }
        guard let expected else { return true }
        return actual == expected
    }
}
