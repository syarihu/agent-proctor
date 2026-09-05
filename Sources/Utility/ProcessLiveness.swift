import Foundation

/// プロセスが生きているかを見る。
///
/// 台帳から記録を落としてよいかの判断に使う。端末に依存しないので、
/// iTerm2 以外で動かしているセッションもこれで片付けられる
/// (iTerm2 に生存を聞く ReapClosedSessions は itermSession を持つものしか見られない)。
///
/// pid だけでは足りない。macOS は pid を使い回すので、死んだセッションの pid が
/// たまたま別のプロセスに当たると、いつまでも生きていることになってしまう。
/// 起動時刻まで一致して初めて「同じプロセス」と見なす。
public enum ProcessLiveness {
    /// その pid の起動時刻 (epoch 秒)。居なければ nil。
    ///
    /// sysctl で読むだけなので fork もプロセス起動もしない。hooks は高い頻度で
    /// 叩かれるうえ、これは台帳のロックの中から全件に対して呼ばれる。
    public static func startedAt(pid: Int) -> Int? {
        guard let pid = Int32(exactly: pid), pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // 居ない pid でも sysctl 自体は成功する。書き込まれた大きさで判断する
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // 終了して親に回収されていないだけの抜け殻は、死んでいるものとして扱う
        guard info.kp_proc.p_stat != SZOMB else { return nil }
        return Int(info.kp_proc.p_starttime.tv_sec)
    }

    /// - Parameter startedAt: 記録したときの起動時刻。持っていない記録もあるので省略可。
    ///   渡さなければ pid が居るかどうかだけで決める (使い回しを弾けない)。
    public static func isAlive(pid: Int, startedAt expected: Int? = nil) -> Bool {
        guard let actual = startedAt(pid: pid) else { return false }
        guard let expected else { return true }
        return actual == expected
    }
}
