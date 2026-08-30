import CoreServices
import Foundation

/// ファイルが変わった場所を FSEvents から受け取る。
///
/// **判断は持たない。** 「どこが変わったか」を答えるだけで、そこを数え直すか、
/// 覚えた数字を出すかを決めるのは呼ぶ側 (`CountChanges` と `TaskStore`)。
///
/// **取りこぼす前提で使うこと。** イベントは合体するし、見張る場所を
/// 張り替えている間の変化は誰にも届かないし、アプリが動いていなかった間の
/// ものは初めから来ない。**ここが黙っていることは「変わっていない」の証にならない**ので、
/// 呼ぶ側はときどき全部を数え直す道を別に持つこと。
///
/// `watch` と `stop` は同じスレッドから呼ぶ (アプリでは `TaskStore` = メイン)。
/// 印を立てるのは FSEvents 側のキューなので、そちらとの間だけロックで守る。
public final class WorktreeWatcher {
    public init() {
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    deinit { stop() }

    /// まだ誰も引き取っていない印があるか。**印は落とさない。**
    ///
    /// 「数え直す値打ちがあるか」を決めるのに、呼ぶ側が自前の旗を持たずに
    /// 済むようにしてある。旗を立てて回す形にすると、旗を立てる報せと
    /// 印を引き取る `takeChanged` が別々のスレッドから来るので、
    /// **引き取った直後に旗だけが立ち、空振りの数え直しが1回入る**
    public var hasChanged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !changed.isEmpty
    }

    /// 見張る場所を入れ替える。同じ顔ぶれなら何もしない
    /// (張り替えは畳んで作り直すことなので、その間のイベントが落ちる)。
    ///
    /// - Parameter roots: 見張る場所 → **そこが動いたときに `takeChanged` が返す名前**。
    ///   ふつうは同じ文字列でよいが、**1つのものが2つの場所に散らばっていることがある**
    ///   (連結 worktree は、作業ツリーと git の置き場を別々に持つ)。
    ///   そういうときは両方を同じ名前で登録する。
    ///   どこがその名前に属するかを決めるのは呼ぶ側で、ここは知らない
    public func watch(_ roots: [String: String]) {
        // 正規化してから比べる。呼ぶ側は台帳と git から来た文字列をそのまま
        // 渡してくるので、揃えずに持つと同じ場所が末尾の `/` の有無で二重に映る
        var resolved: [String: String] = [:]
        for (path, name) in roots {
            let real = Self.resolve(path)
            // 解いた先がぶつかったときの代表は名前で決める。辞書を回る順は
            // 実行のたびに変わるので、任せると同じ顔ぶれでも結果が揺れる
            if let existing = resolved[real], existing <= name { continue }
            resolved[real] = name
        }

        lock.lock()
        // **顔ぶれは集合として比べる。** 並びで比べると、長さの同じパス同士の順が
        // 辞書の回り方で入れ替わるたびに、中身が同じなのに張り替えが走る
        guard resolved != watched else { lock.unlock(); return }
        watched = resolved
        // 長いほうから当てるために並べておく (理由は `note`)。
        // 長さが同じものはパスで決着をつける。**`name` では決着しない** ——
        // 1つの名前に2つの場所が付くことがあるので、並びが不定になる
        targets = resolved.map { (path: $0.key, name: $0.value) }
            .sorted {
                $0.path.count != $1.path.count
                    ? $0.path.count > $1.path.count : $0.path < $1.path
            }
        // 見張らなくなった場所の印は落とす。誰も聞きに来ないまま溜まる
        changed.formIntersection(resolved.values)
        lock.unlock()

        // ストリームの操作はロックの外でやる。畳むときは FSEvents 側の
        // キューを待ち合わせるので、印を立てようとしている相手を待たせたまま
        // ここで抱えると噛み合う
        tearDown()
        start(resolved.keys.sorted())
    }

    /// 前回ここを呼んでから変化のあったものの名前を返し、印を落とす。
    /// 返るのは `watch` に渡された名前そのもの (呼ぶ側の語彙で答える)
    public func takeChanged() -> Set<String> {
        lock.lock()
        let taken = changed
        changed.removeAll()
        lock.unlock()
        return taken
    }

    /// 見張りを畳む。
    ///
    /// **覚えている顔ぶれごと捨てる。** 残しておくと、次に同じ顔ぶれで `watch` を
    /// 呼ばれたときに「同じだから何もしない」の側に落ちて、ストリームが
    /// 畳まれたまま戻らない
    public func stop() {
        forget()
        tearDown()
    }

    /// FSEvents から届いた絶対パスに印を付ける。呼ばれるのは専用のキューから
    fileprivate func note(_ paths: [String]) {
        var touched: Set<String> = []
        lock.lock()
        for path in paths {
            let hit = path.hasSuffix("/") ? String(path.dropLast()) : path
            // **いちばん長く一致する見張り対象に付ける。** worktree は
            // リポジトリの中 (`.claude/worktrees/X`) に置かれるし、その git の
            // 置き場も本体の中 (`.git/worktrees/X`) にある。前から順に当てると
            // どちらの変化も親のリポジトリの印になり、
            // 肝心の worktree の数字が古いまま残る
            if let target = targets.first(where: {
                hit == $0.path || hit.hasPrefix($0.path + "/")
            }) {
                touched.insert(target.name)
            }
        }
        changed.formUnion(touched)
        lock.unlock()
    }

    private func start(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        // C の関数ポインタは Swift の値を掴めないので、自分自身は生ポインタで預ける。
        // **retain させない。** ストリームに持たせると、畳むまで自分が生き残り、
        // 畳む口 (deinit) には永久に辿り着かない
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // ファイル単位 (kFSEventStreamCreateFlagFileEvents) にはしない。
        // 知りたいのは「どの worktree が動いたか」だけなのに、node_modules や
        // .build にビルドを1回通しただけでイベントが数万件届く。
        // 1秒待って合体させるのも同じ理由
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, watcherCallback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)) else { return forget() }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return forget()
        }
        self.stream = stream
    }

    /// 覚えているものを全部捨てて、次の `watch` を必ず張り直しにする。
    /// **張れなかった回にも通ること** —— 覚えたままにすると、同じ顔ぶれで
    /// 呼ばれる限り「同じだから何もしない」に落ちて、報せが二度と来ない。
    ///
    /// 印 (`changed`) も一緒に落とす。見張っていない場所の印を残すと、
    /// 次に聞きに来た人が「変わった」と受け取って数え直しに行く
    private func forget() {
        lock.lock()
        targets = []
        watched = [:]
        changed.removeAll()
        lock.unlock()
    }

    private func tearDown() {
        guard let stream else { return }
        self.stream = nil
        // 畳むところまでを FSEvents のキューの上でやる。ここを待たないと、
        // 既に解けた自分を掴んだコールバックが後から走りうる
        // (ストリームは自分を retain していないため)。
        //
        // **ただし自分がそのキューの上にいるなら、待たずに直に畳む。**
        // `onChange` はこのキューから呼ばれるので、受け取った側がそのまま
        // `stop()` を呼ぶ道がある。直列キューに自分から `sync` すると
        // そこで固まる。既にキューの上なら、待つべき相手は自分しかいない
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
            close(stream)
        } else {
            queue.sync { close(stream) }
        }
    }

    private func close(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// シンボリックリンクを解いた実体の名前に揃える。
    /// macOS では同じ場所が `/var` と `/private/var` の2つの名前で現れ、
    /// FSEvents が答えるのは実体のほう。揃えておかないと一生当たらない。
    ///
    /// **`URL.resolvingSymlinksInPath()` は使えない。** あちらは解いたうえで
    /// 先頭の `/private` を落として返すので、`/tmp/x` も `/private/tmp/x` も
    /// `/tmp/x` になり、FSEvents が言ってくる `/private/tmp/x` と永久に噛み合わない。
    /// `realpath` は落とさずに実体を返す。解けない (まだ無い) パスは、
    /// せめて末尾の `/` だけ落として返す —— 揃わないまま持つと
    /// 同じ場所が二重に映り、顔ぶれが揺れて張り替えが走り続ける
    private static func resolve(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil { return String(cString: buffer) }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// 「いま**自分の**キューの上か」を見分ける印 (`tearDown` の理由を見よ)。
    /// **誰のキューかまで見る。** 鍵は全インスタンスで共通なので、印を
    /// 置いてあるだけだと、隣の見張りのキューの上でも自分だと答えてしまう
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "net.syarihu.proctor.worktree-watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    /// 正規化した場所 → 呼ぶ側に返す名前。長い順に並べて持つ
    private var targets: [(path: String, name: String)] = []
    /// いま張ってある顔ぶれ。張り替えるかどうかはこれと比べて決める
    private var watched: [String: String] = [:]
    private var changed: Set<String> = []
}

private let watcherCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info,
          let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue().note(paths)
}
