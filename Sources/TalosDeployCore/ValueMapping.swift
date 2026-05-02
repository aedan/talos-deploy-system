import Foundation

func stringify(_ value: Any?) -> String {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    default:
        return ""
    }
}

func integer(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let string as String:
        return Int(string)
    case let number as NSNumber:
        return number.intValue
    default:
        return nil
    }
}

func stringArray(_ value: Any?) -> [String] {
    if let strings = value as? [String] {
        return strings
    }
    if let string = value as? String, !string.isEmpty {
        return [string]
    }
    return []
}
