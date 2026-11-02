import Foundation

/// What the session model and its centers keep across a quit, as
/// `UserDefaults` answers it. A test gives a dictionary instead, so nothing
/// it does lands in a preferences file.
protocol Defaults: AnyObject {
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func bool(forKey key: String) -> Bool
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: Defaults {}
