import Foundation
import Model
import RepositoryAdjutant

/// adjutant の hub 記録と台帳の行を突き合わせて、どのセッションが常駐ハブかを決める。
public enum ResolveHubSessions {
    /// ハブとして扱う台帳 ID の集合。
    ///
    /// adjutant を入れていなければ記録が無いので空が返り、何も起こらない。
    public static func hubIDs(among records: [TaskRecord],
                              hubs: [AdjutantHub] = AdjutantHubStore.hubs()) -> Set<String> {
        guard !hubs.isEmpty, !records.isEmpty else { return [] }

        var found: Set<String> = []
        var unmatched: [AdjutantHub] = []

        // 1. PID で引く。`adj hub` は exec でエージェント本体に化けるので、
        //    記録の PID は台帳の PID (CLAUDE_PID) と同じものを指す。
        //    作業ディレクトリも一緒に見るのは、macOS が PID を使い回したときに
        //    たまたま番号が一致した無関係のセッションをハブに仕立てないため
        for hub in hubs {
            let hit = records.first { $0.pid == hub.pid && samePath($0.worktree, hub.cwd) }
            if let hit {
                found.insert(hit.id)
            } else {
                unmatched.append(hub)
            }
        }

        // 2. PID を持たないエージェント (Claude Code 以外) で動いているハブの受け皿。
        //    作業ディレクトリしか手がかりが無いので、そこに座っているセッションが
        //    ちょうど1つのときだけ採用する。2つ以上あるなら、どちらがハブかは
        //    このやり方では決まらない。間違ったほうを見出し机に座らせるより、何も動かさない
        for hub in unmatched {
            let candidates = records.filter { samePath($0.worktree, hub.cwd) && !found.contains($0.id) }
            if candidates.count == 1, let only = candidates.first {
                found.insert(only.id)
            }
        }

        return found
    }

    /// 同じ場所を指しているか。末尾のスラッシュだけが違うものを別物にしない
    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ path: String) -> String {
            var trimmed = path
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }
        return normalized(lhs) == normalized(rhs)
    }
}
