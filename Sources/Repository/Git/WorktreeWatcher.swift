import CoreServices
import Foundation

/// FSEvents を使用してファイル変更を検知するウォッチャー。
///
/// 変更があったパスを特定して通知する責務のみを担い、再集計の要否判断は上位層（TaskStore 等）が行う。
/// イベントの合体や監視切り替え時のタイムラグがあるため、定期的な完全再集計との併用を前提とする。
///
/// `watch` および `stop` は同一スレッド（メインスレッド等）から呼び出される想定。
/// イベントキューからの通知受付との同期はロックで行う。
public final class WorktreeWatcher {
    public init() {
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    deinit { stop() }

    /// 未取得の変更イベントが存在するかどうか（フラグはリセットしない）。
    public var hasChanged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !changed.isEmpty
    }

    /// 監視対象パスを更新する。対象に変更がない場合は何もしない。
    ///
    /// - Parameter roots: 監視対象パス → 変更検知時に `takeChanged` が返す識別名のマッピング。
    ///   連結 worktree のように作業ツリーと git 管理ディレクトリが分かれている場合は、
    ///   両方のパスに同一の識別名を割り当てる。
    public func watch(_ roots: [String: String]) {
        // パスを正規化して比較する（末尾スラッシュ等の表記揺れを吸収するため）
        var resolved: [String: String] = [:]
        for (path, name) in roots {
            let real = Self.resolve(path)
            if let existing = resolved[real], existing <= name { continue }
            resolved[real] = name
        }

        lock.lock()
        // 監視対象パス集合に変化がなければスキップ
        guard resolved != watched else { lock.unlock(); return }
        watched = resolved
        // 最長一致で判定できるようパス文字列長の降順でソート
        targets = resolved.map { (path: $0.key, name: $0.value) }
            .sorted {
                $0.path.count != $1.path.count
                    ? $0.path.count > $1.path.count : $0.path < $1.path
            }
        // 監視対象外となったパスの変更通知を破棄
        changed.formIntersection(resolved.values)
        lock.unlock()

        tearDown()
        start(resolved.keys.sorted())
    }

    /// 前回の呼び出し以降に変更があった識別名の集合を返し、変更記録をクリアする。
    public func takeChanged() -> Set<String> {
        lock.lock()
        let taken = changed
        changed.removeAll()
        lock.unlock()
        return taken
    }

    /// 監視を停止し、登録済みの対象パスを破棄する。
    public func stop() {
        forget()
        tearDown()
    }

    /// FSEvents コールバックから受け取った変更パスを記録する。
    fileprivate func note(_ paths: [String]) {
        var touched: Set<String> = []
        lock.lock()
        for path in paths {
            let hit = path.hasSuffix("/") ? String(path.dropLast()) : path
            // 最長一致する監視対象に割り当てる。
            // worktree や git 管理ディレクトリが親リポジトリ配下に位置する場合に正しく個別判定するため。
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
        // C の関数ポインタに self を生ポインタで渡す。
        // 循環参照による解放漏れを防ぐため retain は行わない（retain すると deinit に到達しなくなる）。
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // ビルド成果物等による大量のイベント発生を抑止するため、
        // ファイル単位ではなくディレクトリ単位で監視し、1.0 秒のレイテンシで合体通知させる。
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

    /// 登録対象パスおよび変更フラグを破棄し、次回 `watch` 時に確実にストリームが再構築されるようにする。
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
        // FSEvents キュー上で安全にストリームをクローズする。
        // 自キュー上で実行中の場合はデッドロックを避けるため sync せず直接クローズする。
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

    /// シンボリックリンクを実体パスに解決する。
    /// macOS では同一パスが `/var` と `/private/var` の双方で参照されうるが、
    /// FSEvents は実体パスで通知するため `realpath` で実体パスに統一する。
    private static func resolve(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil { return String(cString: buffer) }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// 自身のディスパッチキュー上かどうかを識別するキー (tearDown 時のデッドロック防止用)
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "net.syarihu.proctor.worktree-watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    /// 正規化済みパスと識別名のペア（最長一致判定のためパス長の降順で保持）
    private var targets: [(path: String, name: String)] = []
    /// 現在監視中のパスと名前のマップ（監視ストリーム再構築要否の比較用）
    private var watched: [String: String] = [:]
    private var changed: Set<String> = []
}

private let watcherCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info,
          let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue().note(paths)
}
