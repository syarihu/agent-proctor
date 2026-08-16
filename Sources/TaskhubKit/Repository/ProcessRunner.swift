import Foundation

/// 外部コマンドを動かす口。git も gh も studio もここを通る。
public enum ProcessRunner {
    /// コマンドを実行して stdout を返す。stderr は既定で親にそのまま流す。
    ///
    /// 出力は待ち合わせる前に読み切る。パイプの容量を超えると子が書き込みで
    /// 止まり、待っているこちらと睨み合いになる。
    @discardableResult
    public static func run(_ cmd: [String], cwd: String? = nil,
                           check: Bool = true, quiet: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = cmd
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let out = Pipe()
        process.standardOutput = out
        if quiet { process.standardError = FileHandle.nullDevice }

        do {
            try process.run()
        } catch {
            if check {
                throw TaskhubError("コマンドを起動できません: " + cmd.joined(separator: " "))
            }
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if check && process.terminationStatus != 0 {
            throw TaskhubError("コマンドが失敗しました: " + cmd.joined(separator: " "))
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 出力を横取りせずに実行し、終了コードだけ返す。
    ///
    /// `taskhub diff` のように、ページャや色付きの出力をそのまま人に見せたいとき用。
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

    /// (成功したか, stdout) を返す。
    ///
    /// 失敗と「結果が空」を区別したいときに使う。消す前の確認のように、
    /// 確かめられなかったことを素通りさせてはいけない場面がある。
    public static func capture(_ cmd: [String], cwd: String? = nil) -> (ok: Bool, output: String) {
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

    /// PATH 上にそのコマンドがあるか。
    public static func exists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
