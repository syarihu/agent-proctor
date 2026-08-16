import Foundation
import TaskhubKit

/// hooks から状態を書き込む。人が直接使うことは想定していない。
///
/// TASKHUB_ID にもセッションIDにも worktree にも当たらなければ、対話セッションとして
/// 登録する。これにより taskhub 経由でなく普通に開いた claude も一覧に並ぶ。
/// 記録した状態を stdout に返す。呼び出し側が「結局どうなったか」を使えるようにする
/// (タブの色を変えるなど)。判断をシェル側に写すと、片方だけ直したときに食い違う。
func cmdTouch(_ args: Args) throws -> Int32 {
    var status = try args.require(0, "状態 (running|waiting|done|clear|notification)")
    guard ["running", "waiting", "done", "clear", "notification"].contains(status) else {
        throw TaskhubError(
            "状態は running/waiting/done/clear/notification のいずれかです: \(status)")
    }

    let payload = Hooks.readPayload()

    // notification は権限確認でもアイドル通知でも飛んでくる。
    // どちらなのかの判断はここが持つ
    if status == "notification" {
        guard let resolved = Hooks.resolveNotification(payload) else {
            return 0  // アイドル通知。何も出さないことで「変えない」を伝える
        }
        status = resolved
    }
    // 台帳を触る前に返す。git の外での実行など、記録しない場合でも
    // 「このイベントは確認待ちを意味する」ことは呼び出し側に伝わってほしい
    print(status)
    let sessionID = Hooks.sessionID(from: payload)
    let top = Hooks.gitToplevel(cwd: Hooks.cwd(from: payload))
    guard !top.isEmpty else { return 0 }  // git の外での実行は追いかけない

    let now = Int(Date().timeIntervalSince1970)
    try Ledger.withLocked { state in
        Hooks.pruneSessions(&state)

        guard let index = Hooks.findTaskIndex(in: state, payload: payload, top: top) else {
            // 新しく登録するのは、これから動き出すときだけにする。
            //
            // done や clear が単独で届くのは、終了処理が入れ違いになったときで
            // (clear は同期・done は非同期なので追い越しうる)、ここで作ると
            // 終わったはずのセッションが幽霊として一覧に戻ってしまう。
            //
            // セッションIDが取れないものも登録しない。次に来たときに照合できず、
            // 呼ばれるたびに新しいタスクが積み上がる。
            guard status == "running" || status == "waiting", let sessionID else { return }
            let repo = (try? Config.repoRoot(start: top, strict: false)) ?? top
            let branch = (try? git(top, "rev-parse", "--abbrev-ref", "HEAD",
                                   check: false, quiet: true)) ?? ""
            state.tasks.append(TaskRecord(
                id: try Ledger.uniqueID(
                    base: slugify(URL(fileURLWithPath: top).lastPathComponent),
                    taken: state.tasks),
                repo: repo,
                branch: branch.isEmpty ? "-" : branch,
                worktree: top,
                base: (try? Config.detectBaseBranch(repo: top)) ?? "main",
                sessionId: sessionID,
                itermSession: Iterm.sessionID(),
                kind: "session",
                status: status,
                createdAt: now,
                updatedAt: now))
            return
        }

        if status == "clear" {
            if state.tasks[index].isSession {
                // セッションが終わったら一覧から消す。worktree を持つタスクは残す
                state.tasks.remove(at: index)
            } else {
                state.tasks[index].status = "idle"
                state.tasks[index].updatedAt = now
            }
            return
        }

        // 変わったところだけ触る。何も変わらなければ Ledger.withLocked が
        // 書き込みごと省くので、台帳の更新時刻が動かずサイドバーも数え直さない。
        // PostToolUse のように何度も飛んでくるイベントを受けられるのはこのため
        if state.tasks[index].status != status {
            state.tasks[index].status = status
            state.tasks[index].updatedAt = now
        }
        if let sessionID, state.tasks[index].sessionId != sessionID {
            state.tasks[index].sessionId = sessionID
        }
        if let iterm = Iterm.sessionID(), state.tasks[index].itermSession != iterm {
            state.tasks[index].itermSession = iterm
        }
        if status == "done", (state.tasks[index].subagents ?? 0) != 0 {
            // ターンが終わればサブエージェントは残らない。
            // 取りこぼしでずれた数をここで戻す
            state.tasks[index].subagents = 0
        }
    }
    return 0
}

/// サブエージェントの増減を数える。
///
/// PreToolUse(Task) で増やし、SubagentStop で減らす。取りこぼしても
/// ターンの終わり (_touch done) で 0 に戻すので、ずれたままにはならない。
func cmdSubagent(_ args: Args) throws -> Int32 {
    let action = try args.require(0, "start か stop")
    guard action == "start" || action == "stop" else {
        throw TaskhubError("start か stop を指定してください: \(action)")
    }
    let payload = Hooks.readPayload()
    let top = Hooks.gitToplevel(cwd: Hooks.cwd(from: payload))
    let delta = action == "start" ? 1 : -1

    try Ledger.withLocked { state in
        guard let index = Hooks.findTaskIndex(in: state, payload: payload, top: top)
        else { return }
        state.tasks[index].subagents = max(0, (state.tasks[index].subagents ?? 0) + delta)
        state.tasks[index].updatedAt = Int(Date().timeIntervalSince1970)
    }
    return 0
}

/// statusline から呼ばれる。セッション名・モデル・コンテキスト使用率を台帳に流す。
///
/// hooks の payload には来ず statusline にしか届かない情報なので、ここで横流しする。
func cmdStats(_ args: Args) throws -> Int32 {
    try Hooks.recordSessionStats(Hooks.readPayload())
    return 0
}
