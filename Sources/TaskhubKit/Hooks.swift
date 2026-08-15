import Foundation

/// hooks と statusline から流れてくる情報の受け口。
///
/// Claude Code と Antigravity の両方から呼ばれるので、キーの名前は
/// どちらの流儀も受ける。
public enum Hooks {
    /// 終了を取りこぼした対話セッションの記録を捨てるまでの猶予
    public static let sessionTTL = 24 * 3600

    /// hook が stdin に流してくる JSON。人が手で叩いたときは空になる。
    public static func readPayload() -> [String: Any] {
        guard isatty(0) == 0 else { return [:] }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// セッションが動いている worktree のルート。
    ///
    /// サブディレクトリで起動されていても同じタスクに寄せたいので正規化する。
    /// 台帳のパスと突き合わせるため、シンボリックリンクも解決しておく。
    /// 経路によって解決の有無が違うと、同じ場所を別物として扱ってしまう。
    public static func gitToplevel(cwd: String) -> String {
        let (ok, top) = gitTry(cwd, "rev-parse", "--show-toplevel")
        guard ok, !top.isEmpty else { return "" }
        return URL(fileURLWithPath: top).resolvingSymlinksInPath().path
    }

    /// フックや statusline の payload から session ID を引く。
    ///
    /// Claude の session_id と Antigravity の conversationId / conversation_id の
    /// 両方に対応する。
    public static func sessionID(from payload: [String: Any]) -> String? {
        for key in ["session_id", "conversationId", "conversation_id"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// フックの payload から作業ディレクトリを引く。
    public static func cwd(from payload: [String: Any]) -> String {
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
        if let paths = payload["workspacePaths"] as? [String], let first = paths.first {
            return first
        }
        return FileManager.default.currentDirectoryPath
    }

    /// hook の情報から対象のタスクの添字を引く。
    ///
    /// TASKHUB_ID → セッションID → worktree のパス、の順に照合する。
    /// セッションIDを先に見るのは、同じ場所で複数のセッションが開いていても
    /// 取り違えないため。
    public static func findTaskIndex(in state: StateFile, payload: [String: Any],
                                     top: String? = nil) -> Int? {
        if let envID = ProcessInfo.processInfo.environment["TASKHUB_ID"], !envID.isEmpty,
           let index = state.tasks.firstIndex(where: { $0.id == envID }) {
            return index
        }
        let session = sessionID(from: payload)
        if let session,
           let index = state.tasks.firstIndex(where: { $0.sessionId == session }) {
            return index
        }
        guard let top, !top.isEmpty else { return nil }

        // 場所での照合は taskhub が作ったタスクにだけ効かせる。
        // 対話セッションは同じリポジトリで何枚も開くものなので、ここで
        // まとめてしまうと2枚目以降が1枚目の記録を上書きして消えてしまう
        guard let index = state.tasks.firstIndex(where: {
            $0.worktree == top && !$0.isSession
        }) else { return nil }

        // すでに別のセッションが使っている worktree なら譲る。
        // 取り合うと状態とセッションIDが交互に書き換わり、
        // 片方が動いていても完了に見えてしまう
        let owner = state.tasks[index].sessionId
        if let session, let owner, owner != session { return nil }
        return index
    }

    /// 終了を取りこぼした対話セッションの記録を捨てる。
    ///
    /// SessionEnd が飛ばないまま終わることがあるため、古くなったものは掃除する。
    /// worktree を持つタスクは実体があるので対象にしない。
    ///
    /// 実行中のものも残す。更新時刻は状態が変わったときだけ動くので、
    /// 長いターンを回している間は時刻が古いままになる。まさに追いかけたい
    /// 「夜通し動いているエージェント」を消してしまっては本末転倒になる。
    public static func pruneSessions(_ state: inout StateFile, now: Int? = nil) {
        let cutoff = now ?? Int(Date().timeIntervalSince1970)
        state.tasks.removeAll { task in
            task.isSession
                && task.status != "running"
                && cutoff - task.updatedAt >= sessionTTL
        }
    }

    /// statusline から呼ばれ、セッション名・モデル・コンテキスト使用率を台帳に足す。
    ///
    /// hooks では取れずここにしか来ない情報を横流しするための入り口。
    /// statusline は描画のたびに呼ばれるため、内容が変わらないときは書き込まない。
    /// 書くと台帳の更新時刻が動いてサイドバーが無駄に数え直す。
    public static func recordSessionStats(_ payload: [String: Any]) throws {
        guard let session = sessionID(from: payload) else { return }

        var model: String?
        if let box = payload["model"] as? [String: Any] {
            model = (box["display_name"] as? String)
                ?? (box["id"] as? String)
                ?? (box["name"] as? String)
        } else if let value = payload["model"] as? String, !value.isEmpty {
            model = value
        }

        var contextPercent: Double?
        if let box = payload["context_window"] as? [String: Any] {
            if let used = box["used_percentage"] as? Double {
                contextPercent = used
            } else if let current = box["current"] as? Double,
                      let limit = box["limit"] as? Double, limit > 0 {
                contextPercent = current / limit * 100
            }
        } else if let value = payload["context_window"] as? Double {
            contextPercent = value
        }
        let rounded = contextPercent.map { Int($0.rounded()) }

        var name: String?
        for key in ["session_name", "title", "session_title"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { name = trimmed; break }
            }
        }

        // まだ hooks が登録していないセッションなら何もしない。登録はそちらに任せる。
        // ここで先に読んで確かめるのは、変化が無いときにロックを取らないため
        guard let current = Ledger.loadTasks().first(where: { $0.sessionId == session })
        else { return }
        if current.name == name && current.model == model
            && current.contextPercent == rounded { return }

        try Ledger.withLocked { state in
            guard let index = state.tasks.firstIndex(where: { $0.sessionId == session })
            else { return }
            state.tasks[index].name = name
            state.tasks[index].model = model
            state.tasks[index].contextPercent = rounded
        }
    }
}
