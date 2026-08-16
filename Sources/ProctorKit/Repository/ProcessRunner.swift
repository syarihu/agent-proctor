import Foundation

/// 外部コマンドを動かす口。git の呼び出しはすべてここを通る。
public enum ProcessRunner {
    /// (成功したか, stdout) を返す。
    ///
    /// 失敗と「結果が空」を区別できるようにしてある。git は聞き方によって
    /// 「答えが無い」と「聞けなかった」の両方が空で返るので、
    /// 呼び出し側がそれを取り違えないようにする。
    ///
    /// 出力は待ち合わせる前に読み切る。パイプの容量を超えると子が書き込みで
    /// 止まり、待っているこちらと睨み合いになる。
    public static func capture(_ cmd: [String],
                               cwd: String? = nil) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, text)
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
