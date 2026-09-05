import Foundation
import Model
import RepositoryLedger

/// 「もう知らせなくていい」を人が押したときの片付け。
///
/// **通知から降ろすだけでは済まない。** 一覧の行が確認待ちのまま残っていると、
/// 上では片付いていて下では待たせている、という食い違いになる。
/// だから台帳の状態まで動かす。
///
/// hooks から届く `TaskStatus.settled` と分けているのは、意味が違うから。
/// あちらは「あのプロンプトはもう無い」という**事実の観測**なので、
/// 終わったものを見たことにはしない。こちらは人が「もういい」と言っているので、
/// 未読の印まで落とす。
///
/// **押しても戻ってくることがある。** 権限確認のプロンプトが実際に開いたままなら、
/// その6秒後に届く `Notification` がまた確認待ちにする。これは嘘ではない
/// (本当に待たせている) ので、抑え込む仕掛けは置いていない。
/// 黙らせたいだけなら、もう一度押せばよい。
public enum ClearAttention {
    /// 単一のセッションの要確認マークを降ろす。
    ///
    /// - Parameter id: 片付ける台帳の ID。**要確認に出ていたものを渡す。**
    ///   押してから台帳に届くまでに状態が変わっていることはあるので、
    ///   何を片付けてよいかはここで改めて確かめる
    /// - Returns: 台帳を書き換えたら true
    @discardableResult
    public static func clear(id: String) throws -> Bool {
        guard !id.isEmpty else { return false }
        return try clear(ids: [id])
    }

    /// - Parameter ids: 片付ける台帳の ID。**要確認に出ていたものを渡す。**
    ///   押してから台帳に届くまでに状態が変わっていることはあるので、
    ///   何を片付けてよいかはここで改めて確かめる
    /// - Returns: 台帳を書き換えたら true
    @discardableResult
    public static func clear(ids: [String]) throws -> Bool {
        let targets = Set(ids)
        guard !targets.isEmpty else { return false }

        // 変化が無いときにロックを取らない (MarkSessionSeen と同じ考え方)。
        // 何度押されても、片付いた後の分はここで止まる
        guard LedgerStore.tasks().contains(where: {
            targets.contains($0.id) && needsClearing($0)
        }) else { return false }

        let now = Int(Date().timeIntervalSince1970)
        try LedgerStore.withLock { ledger in
            for index in ledger.tasks.indices
            where targets.contains(ledger.tasks[index].id)
                && needsClearing(ledger.tasks[index]) {
                clear(&ledger.tasks[index], now: now)
            }
        }
        return true
    }

    /// 片付ける相手か。**要確認に出す条件と揃える** (`CollectTasks.awaitingReview`)。
    /// 走っているものや、もう見たものが混ざっていても何もしない
    static func needsClearing(_ task: TaskRecord) -> Bool {
        switch task.status {
        case TaskStatus.waiting: return true
        case TaskStatus.done, TaskStatus.failed: return task.seenAt == nil
        default: return false
        }
    }

    private static func clear(_ task: inout TaskRecord, now: Int) {
        guard task.status == TaskStatus.waiting else {
            // 終わった・落ちたものは「見た」ことにするだけ。状態は変えない
            // (失敗は見たあとも失敗のまま出す。片付いたわけではないため)
            task.seenAt = now
            return
        }
        // 待たせていたものを人が下ろした。**完了にはしない** ——
        // 何をしていたかは分からないので、見るべき結果があることにしてはいけない
        standDown(&task)
        // **`updatedAt` は動かさない。** あれは「最後に仕事が動いた時刻」で、
        // 一覧の並び (経過の短い順) もそれで決まる。片付けただけで動かすと、
        // 静かにしたくて押したのに、そのまとまりが「今動いた」位置へ跳ね上がる
    }

    /// 確認待ちを降ろす。**人が押したときも、アイドル通知で降ろすとき
    /// (`TaskStatus.settled`) も、ここを通す。**
    ///
    /// 子が走っているなら待機ではなく実行中に戻す。待機にすると
    /// **走っている最中のサブエージェントが一覧から消える**
    /// (子を出すのは実行中と確認待ちのときだけ = `CollectedTask.currentSubagents`)。
    /// しかも子のイベントは親の状態を変えないので、親に何か起きるまで隠れ続ける。
    ///
    /// - Returns: 書き込んだ状態
    @discardableResult
    static func standDown(_ task: inout TaskRecord) -> String {
        task.request = nil
        guard hasLiveChildren(task) else {
            task.status = TaskStatus.idle
            return TaskStatus.idle
        }
        task.status = TaskStatus.running
        // **最後の子が帰ったら待機に落ちるよう預けておく。** でないと、もう誰も
        // 動いていないのに実行中のまま居座る —— 降ろす相手はキャンセルされた
        // ターンか、人が黙らせた行なので、Stop はもう来ない。
        //
        // 既に終わり (done / failed) を預かっているならそちらを残す。
        // あれは親が本当に終わったという知らせで、こちらの当て推量より確か
        if task.pendingStatus == nil { task.pendingStatus = TaskStatus.idle }
        return TaskStatus.running
    }

    /// 子が走っているか。**両方の経路を見る** —— 1体ずつ送ってくる
    /// エージェントと、数だけを送ってくるエージェントがいる。数のほうを
    /// 見落とすと、子が動いているのに待機と書いてしまう
    /// (行には 🤖 の数だけが出たまま残る)
    static func hasLiveChildren(_ task: TaskRecord) -> Bool {
        !(task.subagentRuns ?? []).isEmpty || (task.subagents ?? 0) > 0
    }
}
