import Foundation

/// 外部コマンドを動かす口。git の呼び出しはすべてここを通る。
public enum ProcessRunner {
    /// (成功したか, stdout) を返す。
    ///
    /// 失敗と「結果が空」を区別できるようにしてある。git は聞き方によって
    /// 「答えが無い」と「聞けなかった」の両方が空で返るので、
    /// 呼び出し側がそれを取り違えないようにする。
    ///
    /// - Parameter timeout: タイムアウト秒数。超過時はプロセスを終了させる。
    ///   ネットワーク通信を伴う外部コマンド (gh など) の無応答によるブロックを防ぐために指定する。
    public static func capture(_ cmd: [String],
                               cwd: String? = nil,
                               timeout: TimeInterval? = nil) -> (ok: Bool, output: String) {
        // タイムアウト指定の有無で処理を分ける。指定がない場合は一時ファイルを作成せず実行する。
        guard let timeout else { return inlineCapture(cmd, cwd: cwd) }
        return boundedCapture(cmd, cwd: cwd, limit: timeout)
    }

    /// タイムアウトなしで実行する。
    ///
    /// 出力は完了待機前に読み切る (パイプ容量超過によるデッドロック防止)。
    /// Foundation の `waitUntilExit()` は内部で RunLoop を50ms刻みでポーリングするため、
    /// 短時間で終わるコマンドの待ち時間を削減するために軽量なポーリングを行う。
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

    /// タイムアウト付きで実行する。
    ///
    /// 出力の受け皿に一時ファイルを使用する。
    /// パイプを使用した場合、読み取りスレッドのブロックや孫プロセスの fd 保持によるハングを
    /// 外部から安全にキャンセルできないため。ファイル出力であればプロセスの終了監視のみで完結できる。
    private static func boundedCapture(_ cmd: [String], cwd: String?,
                                        limit: TimeInterval) -> (ok: Bool, output: String) {
        // mkstemp でファイル作成とオープンを不可分に行う
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
            // 猶予期間を過ぎても停止しない場合は、実行中プロセスに対する terminationStatus 参照によるクラッシュ（NSInvalidArgumentException）を防ぐためステータスを参照せず中断する
            guard waitForExit(process, within: grace) else { return (false, "") }
        }
        // 出力ファイルの読み込みに失敗した場合は失敗として扱う
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sinkPath)) else {
            return (false, "")
        }
        return (process.terminationStatus == 0, text(from: data))
    }

    /// 指定時間内にプロセスが終了するのを待つ。
    /// 時刻合わせの影響を受けないよう DispatchTime でタイムアウトを計測する。
    private static func waitForExit(_ process: Process, within limit: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + limit
        while process.isRunning {
            if DispatchTime.now() >= deadline { return false }
            usleep(pollInterval)
        }
        return true
    }

    /// プロセス終了まで待機する (inlineCapture 用)。
    /// 短時間のコマンド向けに短い間隔でポーリングする。
    private static func waitForExit(_ process: Process) {
        while process.isRunning { usleep(inlinePollInterval) }
    }

    /// SIGTERM 送信後のプロセス終了猶予時間（秒）
    private static let grace: TimeInterval = 2
    /// タイムアウト付き実行時のプロセス終了ポーリング間隔（マイクロ秒）
    private static let pollInterval: UInt32 = 20_000
    /// 短時間コマンド（inlineCapture）向けのプロセス終了ポーリング間隔（マイクロ秒）
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
