import Foundation

/// いま動いているセッションに、そのセッション自身が名前を付ける。
///
/// **人が付ける名前 (`tab_title`) と同じ欄 (`TaskRecord.title`) に書く。**
/// 一覧が出すのは `displayName` = `title ?? name ?? id` で、`name` には
/// エージェントが会話から勝手に決めたタイトルが入る。あれは的外れなことがあるので、
/// 「この作業はこれ」と決めた名前を上に置く欄がもとから空いていた。
/// 書く側が居なかっただけなので、欄は増やさずそこへ書く。
///
/// どのセッションかを引数で受けないのがこの UseCase の肝で、理由は `locate` に書いた。
public enum NameSession {
    /// いま自分が居るセッションの行を、環境変数から引き当てる。
    ///
    /// **場所 (cwd) では引けない。** 同じ worktree に何枚もタブを開くし、
    /// セッションを始めた場所と、エージェントが Bash を叩くときの cwd はずれる。
    /// 台帳のIDを引数で受ける手もあるが、エージェントは自分のIDを知らない
    /// (知るには一覧を読んで自分を当てる必要があり、それができるなら苦労はない)。
    ///
    /// 鍵は4つ。上から順に試す。**確からしさは上2つと下2つで違う。**
    ///
    /// 上2つは `RecordHookEvent.findTask` が見ているのと同じ鍵で、順番もそちらに
    /// 揃えてある。揃えないと「hooks は別の行を見ているのに、名前だけこちらに付く」
    /// が起きる。
    ///
    /// 1. `PROCTOR_ID` —— 名指し。自動で載るものではないが、**死んでいる訳ではない**。
    ///    どの鍵でも引けなかったときに `error.session.unidentified` で案内するのが
    ///    これなので、人が手で立てる逃げ道として生きている。消さないこと。
    ///    先頭に置くのは `findTask` がそうしているため
    /// 2. `CLAUDE_CODE_SESSION_ID` —— 台帳の `sessionId` と同じ値。
    ///    Claude Code ならこれで hooks と同じ行に必ず当たる
    ///
    /// 下2つは `findTask` に対応物が無い**受け皿**で、当たった行が hooks の
    /// 書いている行と同じである保証は無い (どちらもセッションではなく、
    /// セッションが載っている入れ物を指す鍵なので、開き直しや使い回しで
    /// 2件以上に当たりうる)。だから `newest` を通して、いちばん最近動いた行に賭ける。
    /// 引き当ては4鍵とも `newest` を通すが、2件以上に当たりうるのはこの下2つだけで、
    /// 上2つでは1件に決まる (揃えてあるのは、鍵ごとに書き方を変えないため)。
    ///
    /// 3. `ITERM_SESSION_ID` —— タブ。**自動で載る鍵としては、agy / codex で効く唯一のもの**
    ///    (`PROCTOR_ID` を手で立てればあちらでも引けるが、それは人の手が要る)。
    ///    同じタブでセッションを開き直した残骸に当たりうる
    /// 4. `CLAUDE_PID` —— 上が全部外れたときの最後の受け皿。
    ///    macOS は pid を使い回すので、別のプロセスの行に当たりうる
    ///
    /// - Parameter environment: 差し替えられるようにしてあるのは試験のため
    /// - Returns: 引けなければ nil
    public static func locate(
        in tasks: [TaskRecord],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TaskRecord? {
        if let envID = EnvironmentSource.taskID(environment),
           let hit = newest(tasks.filter { $0.id == envID }) {
            return hit
        }
        if let session = EnvironmentSource.claudeSessionID(environment),
           let hit = newest(tasks.filter { $0.sessionId == session }) {
            return hit
        }
        // 空文字は「無い」と同じ。台帳側にも空で入っている行があると、
        // 空同士が一致して赤の他人の行に名前が付く
        if let iterm = EnvironmentSource.itermSessionID(environment), !iterm.isEmpty,
           let hit = newest(tasks.filter { $0.itermSession == iterm }) {
            return hit
        }
        if let pid = EnvironmentSource.agentPID(environment),
           let hit = newest(tasks.filter { $0.pid == pid }) {
            return hit
        }
        return nil
    }

    /// 同じ鍵で2件以上当たったときは、**最後に動いたほうを取る**。
    ///
    /// 同じタブで開き直したセッションの残骸 (掃除は次のフックまで走らない) や、
    /// macOS が pid を使い回した結果として起きる。どちらかを選ばざるを得ないなら、
    /// いま喋っているのは新しいほうなので、そちらに賭ける
    private static func newest(_ candidates: [TaskRecord]) -> TaskRecord? {
        candidates.max { $0.updatedAt < $1.updatedAt }
    }

    /// いま自分が居るセッションに名前を付ける。空文字なら外す。
    ///
    /// - Returns: 書き換えたあとの記録。呼ぶ側が「何にどう付いたか」を言えるようにする
    @discardableResult
    public static func run(title raw: String) throws -> TaskRecord {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空文字は「外す」。`tab_title` の扱いと揃えてある
        let value = trimmed.isEmpty ? nil : trimmed

        // 引き当てはロックの外で済ませる (理由は LedgerStore.withLock)。
        // **ロックの中で locate を呼んではいけない** —— 台帳を読み直すために
        // もう一度ロックを取ると、flock は同一プロセスの別 fd 同士でもブロックするので
        // そこで止まる
        let snapshot = LedgerStore.tasks()
        guard let target = locate(in: snapshot) else {
            throw ProctorError(Localized.text("error.session.unidentified"))
        }
        // 変化が無ければロックを取らない (MarkSessionSeen・ClearAttention と同じ考え方)。
        // 同じ名前を何度叩かれても台帳の更新時刻が動かず、サイドバーも数え直さない
        guard target.title != value else { return target }

        return try LedgerStore.withLock { ledger in
            // ID で引き直す。読んでからロックを取るまでに並びは変わりうるので、
            // さっきの位置をそのまま使うと隣の行に名前が付く
            guard let index = ledger.tasks.firstIndex(where: { $0.id == target.id }) else {
                // 入れ違いで消えていた (セッションが終わった・人が rm した)。
                // 次のフックで登録し直されるので、その回は諦める
                throw ProctorError(Localized.text("error.ledger.not_found", target.id))
            }
            ledger.tasks[index].title = value
            // **`updatedAt` は動かさない。** あれは「最後に仕事が動いた時刻」で、
            // 一覧の並び (経過の短い順) もそれで決まる。名付けただけで動かすと、
            // 名前を付けた拍子にその行が先頭へ跳ね上がる
            return ledger.tasks[index]
        }
    }

    /// 「名前を付けてほしい」と囁くか。付けるなら囁きの本文を返す。
    ///
    /// **注ぐ先は会話の文脈**なので、条件は厳しく絞る。毎ターン出るものを
    /// 1文字でも余計に流すと、それだけ本題の場所が減る。
    ///
    /// - Parameter unnamed: その行にまだ名前が無いか (`RecordHookEvent.Outcome`)。
    ///   台帳を読み直さずに済むよう、書いた本人から持ち帰ってもらう
    public static func namingHint(payload: HookPayload, unnamed: Bool) -> String? {
        // **UserPromptSubmit の stdout だけが会話に注がれる。** 他のイベントで
        // 何か出しても、呼ぶ側がタブの色に使うだけで誰も読まない
        guard payload.isUserPromptSubmit else { return nil }
        // 子の手元で起きたことで親に囁かない (他の判定と揃える)。
        // 子は名前を付ける相手ではないし、付けたところで親の行に付く
        guard payload.subagentID == nil else { return nil }
        // 人が打ったときだけにする。`"system"` は peer message・task notification・
        // 自動継続で、ここを通すとサブエージェントが帰ってくるたびに囁くことになる。
        // **載っていない (nil) なら通す** —— 送ってこないエージェントを黙らせないため
        guard payload.promptSource == nil || payload.promptSource == "user" else { return nil }
        guard unnamed else { return nil }
        return Localized.text("cli.hint.unnamed_session")
    }
}
