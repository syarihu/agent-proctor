import Foundation
import Model
import RepositoryLedger
import Resources
import Utility

/// 実行中のセッション自身からセッション表示名（title）を設定する。
/// ユーザー手動設定のタブ名と同じ TaskRecord.title に記録される。
public enum NameSession {
    /// 環境変数から自セッションの TaskRecord を特定する。
    /// PROCTOR_ID, CLAUDE_CODE_SESSION_ID, ITERM_SESSION_ID, CLAUDE_PID の順で探索する。
    /// - Parameter environment: 環境変数辞書（テスト用に注入可能）
    /// - Returns: 特定された TaskRecord。特定不能なら nil
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
        // 空文字のエントリとの誤一致を防ぐため空文字チェックを行う
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

    /// 同一キーに複数のタスクが該当した場合、最新のタスクを選択する。
    /// 同一秒内の開き直し等で updatedAt が等しい場合に古いタスクが優先されるのを防ぐため、
    /// createdAt も含めた複合キーで比較する。
    private static func newest(_ candidates: [TaskRecord]) -> TaskRecord? {
        candidates.max { ($0.updatedAt, $0.createdAt) < ($1.updatedAt, $1.createdAt) }
    }

    /// 現在のセッションに表示名を設定する。空文字の場合は解除する。
    /// - Returns: 更新後の TaskRecord
    @discardableResult
    public static func name(title raw: String) throws -> TaskRecord {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed

        let snapshot = LedgerStore.tasks()
        guard let target = locate(in: snapshot) else {
            throw ProctorError(Localized.text("error.session.unidentified"))
        }
        // 変更がない場合は不要なファイルロック取得を避ける
        guard target.title != value else { return target }

        return try LedgerStore.withLock { ledger in
            guard let index = ledger.tasks.firstIndex(where: { $0.id == target.id }) else {
                throw ProctorError(Localized.text("error.ledger.not_found", target.id))
            }
            ledger.tasks[index].title = value
            // updatedAt は最終作業時刻を表し一覧順序に影響するため、名前変更では更新しない
            return ledger.tasks[index]
        }
    }

    /// 未命名セッションの場合に名前設定を促すプロンプトヒントを生成する。
    /// 会話コンテキストの圧迫を防ぐため、ユーザーが直接入力したターン開始時のみに限定する。
    /// - Parameter unnamed: 対象タスクに名前が未設定かどうか
    public static func namingHint(payload: HookPayload, unnamed: Bool) -> String? {
        guard payload.isUserPromptSubmit else { return nil }
        guard payload.subagentID == nil else { return nil }
        guard payload.promptSource == nil || payload.promptSource == "user" else { return nil }
        guard unnamed else { return nil }
        return Localized.text("cli.hint.unnamed_session")
    }
}
