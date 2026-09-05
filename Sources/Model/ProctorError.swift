/// ユーザー向けエラーメッセージを保持し、CLI を終了するためのエラー型。
public struct ProctorError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
