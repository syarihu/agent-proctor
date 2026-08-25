import AppKit
import Combine
import ProctorKit

/// Organization のアイコンを預かる。
///
/// **View から直接ファイルを読ませないため**の層。SwiftUI は同じ行を何度でも
/// 描き直すので、描画のたびにディスクを叩くことになるし、まだ落としていない
/// 相手には gh とネットワークを待たせることになる。ここで取りに行き、
/// 取れたら `@Published` で描き直させる。
///
/// アイコンをどこに置き、いつ取り直すかは Kit の `OrganizationGrouping` が
/// 持っている。ここが持つのは「重ねて取りに行かないこと」と
/// 「取れるまで何度か試すこと」の2つ。
@MainActor
final class OrgAvatarStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    /// いま取りに行っている最中の相手。**走らせないためだけの印で、結果は覚えない。**
    ///
    /// SwiftUI は同じ見出しを何度でも描き直すので、これが無いと取得が重なる。
    /// 逆に**失敗したことをここに残してはいけない** —— 残すと二度と
    /// `OrganizationGrouping.avatar` を呼ばなくなる
    private var loading: Set<String> = []

    /// 取れなかったときに試し直す回数 (最初の1回を含む)。
    ///
    /// **打ち止めを設けるのは、取れない相手が居るから。** 消えた組織や
    /// 見せてもらえない組織は何度聞いても取れないので、際限なく試すと
    /// 常駐している間ずっと gh を起こし続けることになる。
    /// 3回・約22分あれば、起動直後にネットワークが不安定だった程度は拾える。
    /// それより長く不調が続いたときは、アプリを立ち上げ直すまでモノグラムのまま
    private static let maxAttempts = 3
    /// 試し直すまでの間。**Kit 側のクールダウン (10分) より長く取る。**
    /// 短いと、向こうが「まだ聞かない」と答えるだけの空振りになる
    private static let retryDelay: Duration = .seconds(11 * 60)

    /// - Parameters:
    ///   - owner: GitHub の login 名
    ///   - host: 持ち主が居るホスト。GitHub 以外は Kit 側で弾かれる
    func load(owner: String, host: String) async {
        guard images[owner] == nil, !loading.contains(owner) else { return }
        // 試し直しのあいだも印を立てておく。外すと、描き直しのたびに
        // もう1本ずつ待ち行列が生まれる
        loading.insert(owner)
        defer { loading.remove(owner) }

        for attempt in 1...Self.maxAttempts {
            if await attemptLoad(owner: owner, host: host) { return }
            // 最後の1回のあとは待たない。誰も待っていない眠りを残さない
            guard attempt < Self.maxAttempts else { return }
            // **見出しが一覧から消えたらそこで諦める。** SwiftUI が `.task` を
            // 畳んでくれるので、居なくなった組織のために眠り続けることはない
            do { try await Task.sleep(for: Self.retryDelay) } catch { return }
        }
    }

    /// - Returns: 取れたら true
    private func attemptLoad(owner: String, host: String) async -> Bool {
        // gh とネットワークを待つのでメインスレッドから外す。
        // 返してもらうのはファイルの場所だけにして、画像そのものはここで開く
        // (NSImage をスレッドをまたいで受け渡さない)
        let file = await Task.detached(priority: .utility) {
            OrganizationGrouping.avatar(owner: owner, host: host)
        }.value
        guard let file else { return false }
        guard let image = NSImage(contentsOf: file) else {
            // 置き場は「いつ書かれたか」しか見ていないので、中身が壊れていても
            // 期限 (7日) が切れるまで同じものを返してくる。読めたかどうかを
            // 知っているのはここだけなので、捨てる合図もここから出す
            OrganizationGrouping.discardAvatar(owner: owner)
            return false
        }
        images[owner] = image
        return true
    }
}
