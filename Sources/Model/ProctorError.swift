/// 利用者に見せて終了する種類のエラー。
///
/// これ以外の例外はプログラムの誤りなので、そのまま落ちてよい。
public struct ProctorError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
