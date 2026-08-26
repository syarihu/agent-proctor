import Foundation

/// エージェントに渡す読み物1つぶん。
///
/// 手引きには2種類ある。作業中に読ませる手順 (`proctor skill`) と、
/// proctor を繋ぐための一度きりの設定 (`proctor setup`)。
/// どちらも「名前・題・何が書いてあるか」しか持たないので、器は1つにしてある。
public struct Guide: Encodable, Identifiable, Equatable {
    /// `proctor skill <id>` / `proctor setup <id>` で引く名前
    public var id: String
    public var title: String
    public var summary: String
}
