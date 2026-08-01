import CRustCore
import Foundation

/// T0 计算器服务契约：Swift 工具执行器只依赖本协议，不接触 C 类型。
public protocol CalculatorService: Sendable {
    /// 求值表达式，返回格式化结果文本（如 "7" / "3.5"）。
    func evaluate(_ expression: String) async throws -> String
}

/// 计算器错误。
public enum CalculatorError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidInput(String)
    case evaluationFailed(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return "计算器不可用：\(message)"
        case .invalidInput(let message): return "计算器输入无效：\(message)"
        case .evaluationFailed(let message): return "表达式求值失败：\(message)"
        case .internalError(let message): return "计算器内部错误：\(message)"
        }
    }
}

/// Rust 计算器（dc_eval_expr）：无子进程、无文件 / 网络访问（T2-2b）。
public actor RustCalculatorService: CalculatorService {
    public init() {}

    public func evaluate(_ expression: String) async throws -> String {
        let input = "{\"expr\":\"\(Self.escapeJSON(expression))\"}"
        var out: UnsafeMutablePointer<CChar>? = nil
        let code = input.withCString { dc_eval_expr($0, &out, nil) }
        defer { out.map { dc_free($0) } }

        guard let out else {
            throw CalculatorError.unavailable("Rust 核心不可用")
        }
        let text = String(cString: out)
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CalculatorError.internalError("计算器输出解析失败")
        }

        if code == DC_OK {
            guard let value = json["value"] as? NSNumber else {
                throw CalculatorError.internalError("计算器输出缺少 value")
            }
            return Self.format(value)
        }
        if let message = json["error"] as? String {
            throw CalculatorError.evaluationFailed(message)
        }
        return try Self.mapError(code: code)
    }

    // MARK: - 内部辅助

    private static func escapeJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func format(_ number: NSNumber) -> String {
        if let int = number as? Int {
            return String(int)
        }
        let value = number.doubleValue
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func mapError(code: Int32) throws -> String {
        switch code {
        case DC_ERR_JSON, DC_ERR_INVALID_ARGUMENT:
            throw CalculatorError.invalidInput("表达式 JSON 无效")
        case DC_ERR_UNAVAILABLE:
            throw CalculatorError.unavailable("Rust 核心不可用")
        default:
            throw CalculatorError.internalError("未知错误码 \(code)")
        }
    }
}
