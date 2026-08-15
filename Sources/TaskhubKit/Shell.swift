import Foundation

/// コマンドを実行して stdout を返す。stderr は既定で親にそのまま流す。
///
/// 出力は待ち合わせる前に読み切る。パイプの容量を超えると子が書き込みで
/// 止まり、待っているこちらと睨み合いになる。
@discardableResult
public func run(_ cmd: [String], cwd: String? = nil,
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
        if check { throw TaskhubError("コマンドを起動できません: " + cmd.joined(separator: " ")) }
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
public func runInherit(_ cmd: [String], cwd: String? = nil) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = cmd
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    do { try process.run() } catch { return 127 }
    process.waitUntilExit()
    return process.terminationStatus
}

@discardableResult
public func git(_ repo: String, _ args: String...,
                check: Bool = true, quiet: Bool = false) throws -> String {
    try run(["git", "-C", repo] + args, check: check, quiet: quiet)
}

/// 終了コードだけを見たいとき用。出力は捨てる。
public func gitOK(_ repo: String, _ args: String...) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", repo] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// (成功したか, stdout) を返す。
///
/// 失敗と「結果が空」を区別したいときに使う。消す前の確認のように、
/// 確かめられなかったことを素通りさせてはいけない場面がある。
public func gitTry(_ repo: String, _ args: String...) -> (ok: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", repo] + args
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
public func which(_ name: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", name]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
