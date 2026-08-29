import Foundation

/// 外部コマンドを動かす口。git の呼び出しはすべてここを通る。
public enum ProcessRunner {
    /// (成功したか, stdout) を返す。
    ///
    /// 失敗と「結果が空」を区別できるようにしてある。git は聞き方によって
    /// 「答えが無い」と「聞けなかった」の両方が空で返るので、
    /// 呼び出し側がそれを取り違えないようにする。
    ///
    /// - Parameter timeout: これを過ぎたら子を終わらせる。既定は待ち続ける。
    ///   **ネットワークに出る相手にだけ渡す。** git は手元で完結するので
    ///   返ってこないことがないが、gh は届かないホストを相手にすると
    ///   1分近く黙る。呼んだきり返らないと、その worktree を取りに行った
    ///   ままの印が立ち続けて二度と取り直せなくなる。
    ///   打ち切った子は非0で終わるので、戻りは失敗として扱われる
    public static func capture(_ cmd: [String],
                               cwd: String? = nil,
                               timeout: TimeInterval? = nil) -> (ok: Bool, output: String) {
        // **待ち切りの有無で作りを分ける。** 頼まれていない側は今までどおりで、
        // 一時ファイルも待ち合わせも増やさない。ここは hooks から1手ごとに
        // 何度も通る道 (git) なので、使いもしない仕掛けの分がそのまま積み上がる
        guard let timeout else { return inlineCapture(cmd, cwd: cwd) }
        return boundedCapture(cmd, cwd: cwd, limit: timeout)
    }

    /// 待ち切り無しで走らせる。git の呼び出しはすべてこちらを通る。
    ///
    /// 出力は待ち合わせる前に読み切る。パイプの容量を超えると子が書き込みで
    /// 止まり、待っているこちらと睨み合いになる。
    ///
    /// **終わりを待つのに `waitUntilExit()` を使わない。** Darwin の Foundation は
    /// あの中で RunLoop を50ミリ秒刻みで回すので、20ミリ秒で返る git を待つのに
    /// その刻みの端数をまるごと取られる。実測で1呼び出し84.5ミリ秒、うち約58ミリ秒が
    /// この待ちで、git 本体が動いていたのは平均26ミリ秒だった。同じコマンドを
    /// 覗きに行く形で待つと20.9ミリ秒まで落ちる (4.2倍)。
    /// `proctor worktree ls --all` は git を70回起こすので、この差がそのまま出る
    private static func inlineCapture(_ cmd: [String],
                                      cwd: String?) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        waitForExit(process)
        return (process.terminationStatus == 0, text(from: data))
    }

    /// 待ち切り付きで走らせる。
    ///
    /// **出力の受け皿をパイプではなく一時ファイルにしてある。** パイプにすると、
    /// 待ち切りのために越えないといけない壁が3つ出てくる。
    ///
    /// 1. 読み切るまで待てない (容量を超えると子が書き込みで止まる) ので、
    ///    読む係を別のスレッドに出すことになる
    /// 2. その係は `readDataToEndOfFile` の中で眠るので、**こちらから起こせない。**
    ///    諦めて戻ると、スレッドとファイルディスクリプタを置き去りにする。
    ///    子を殺しても解けないことがある —— **孫が stdout を握り続けている**
    ///    場合で、gh は中で git を起こすのでこれが起こりうる
    /// 3. EOF まで何も手に入らないので、諦めた回は空で返るしかない。
    ///    それを成功として返すと、中身があったのに「空だった」と嘘をつく
    ///
    /// ファイルなら、書く相手は誰であれ勝手に書き、こちらは終わってから読むだけ。
    /// 待つのはプロセスの終わり1つになり、置き去りにするものが無くなる。
    /// **途中まで書かれた分も読める。**
    ///
    /// **期限は「プロセスが終わること」に掛ける。「読み切れること」ではない。**
    /// この2つを取り違えると期限が効かない。stdout を先に閉じてから生き続ける子が
    /// いるので、EOF を合図にすると、そのあとの待ちが期限と無関係に伸びる
    /// (実測で、上限2秒に対して20秒返らなかった)。
    ///
    /// **止めるのは `terminate()` (SIGTERM) だけで、SIGKILL は撃たない。**
    /// ここで起こすもの (git・gh・curl) はどれも SIGTERM で畳めるので、
    /// 受け取らない相手が現れたら、殺さずに手を引くほうを取る。
    ///
    /// **残っている穴を2つ、承知の上で残してある。**
    ///
    /// 1. 生き死にを見てから合図を送るまでの隙に子が終わり、その番号が別の
    ///    プロセスに回っていると、無関係な相手に SIGTERM が飛ぶ。
    ///    `terminate()` も中で pid に撃つので、SIGKILL をやめても閉じない。
    ///    塞ぐには `Process` を捨てて `posix_spawn` と `waitpid` を自前で持ち、
    ///    合図を送り終わるまで子を回収しないようにするしかない。
    ///    起きるには pid が一周して、その一瞬に同じ番号が配られる必要があるので、
    ///    共有の道具をそこまで作り替える釣り合いが取れないと見て置いている
    /// 2. 手を引いた子は生き続け、**一時ファイルを消してもその子の書き込みは止まらない。**
    ///    unlink が消すのは名前だけで、開いている fd はそのまま使えるため
    ///    (名前を失った inode に書き続ける)。書き込みが止まらない子が居座れば、
    ///    その子が終わるまで fd とディスクを掴んだままになる。
    ///    SIGTERM を無視して書き続けるものをここで起こさない、という前提の上に乗っている
    private static func boundedCapture(_ cmd: [String], cwd: String?,
                                       limit: TimeInterval) -> (ok: Bool, output: String) {
        // **作るのと開くのを `mkstemp` で一度に済ませる。** 名前を決めてから開く形だと、
        // 作れたのに開けなかったときに空のファイルが残るし、決めた名前を先回りして
        // 置かれる隙もできる。mkstemp なら他人に読めない権限で、原子的に開かれる
        var template = Array((NSTemporaryDirectory() as NSString)
            .appendingPathComponent("proctor-capture-XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return (false, "") }
        let sinkPath = String(cString: template)
        let sink = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer {
            try? sink.close()
            unlink(sinkPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (false, "") }

        if !waitForExit(process, within: limit) {
            process.terminate()
            // 畳んでもらえなければ手を引く。**まだ走っている `Process` に
            // `terminationStatus` を聞くと落ちる**ので、ここから先へは進まない。
            // 置いていく子と、その子が掴んだままの一時ファイルについては、
            // この関数の説明の「残っている穴」を参照
            guard waitForExit(process, within: grace) else { return (false, "") }
        }
        // **読めなかったものを空として返さない。** 空で成功を返すと、中身があったのに
        // 「無かった」と言うことになる。ここが答える (成功したか, 中身) の
        // 2つ組は、呼ぶ側がまさにその取り違えを避けるために見ている
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sinkPath)) else {
            return (false, "")
        }
        return (process.terminationStatus == 0, text(from: data))
    }

    /// 終わるまで待つ。**期限を掛けられるのが `waitUntilExit()` との違い。**
    ///
    /// 覗きに行く形にしているのは、待つ係を別のスレッドに出さずに済ませるため。
    /// 眠っている係は起こせないので、置き去りにする芽をそもそも作らない。
    /// 20ミリ秒ごとでも、15秒待って750回。呼ぶのは数分に一度なので気にならない
    ///
    /// - Returns: 期限までに終わったら true
    private static func waitForExit(_ process: Process, within limit: TimeInterval) -> Bool {
        // **壁掛け時計 (`Date`) では測らない。** 時刻合わせで巻き戻されると、
        // 上限を過ぎているのに待ち続けることになる。`DispatchTime` は
        // 進むだけの時計なので、そこだけは狂わない
        let deadline = DispatchTime.now() + limit
        while process.isRunning {
            if DispatchTime.now() >= deadline { return false }
            usleep(pollInterval)
        }
        return true
    }

    /// 期限を掛けずに、終わるまで覗きに行く。`inlineCapture` 専用。
    ///
    /// **期限付きの `waitForExit(_:within:)` を流用しない。** あちらが使う間隔は
    /// 20ミリ秒で、これは「15秒待って750回」という gh 側の釣り合いで選ばれた値。
    /// 20ミリ秒で返る git に当てると、最大20ミリ秒の待ち賃が毎回上乗せされ、
    /// `waitUntilExit()` をやめた意味が半分無くなる。
    ///
    /// 眠らずに回さないのは、待っている間ずっと1コアを焼くため。
    /// `usleep` を挟めば、覗きに行く回数が数十回増えるだけで済む
    private static func waitForExit(_ process: Process) {
        while process.isRunning { usleep(inlinePollInterval) }
    }

    /// SIGTERM のあと、畳み終わるのを待つ時間
    private static let grace: TimeInterval = 2
    /// 終わったかを覗きに行く間隔 (マイクロ秒)
    private static let pollInterval: UInt32 = 20_000
    /// 待ち切り無しの側で覗きに行く間隔 (マイクロ秒)。
    /// 相手は数十ミリ秒で終わる git なので、刻みを細かく取る
    private static let inlinePollInterval: UInt32 = 500

    private static func text(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 出力を横取りせずに実行し、終了コードだけ返す。
    /// アプリを起動するときのように、こちらが結果を読まないもの用。
    @discardableResult
    public static func inherit(_ cmd: [String], cwd: String? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        do { try process.run() } catch { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
