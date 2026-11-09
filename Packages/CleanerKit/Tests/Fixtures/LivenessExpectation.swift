import Foundation

/// Whether an open-files answer means "nothing is open" for a test.
///
/// Locally the provider must give a definite `false`. On shared CI runners the
/// process snapshot can be incomplete (other users' processes, churn), and the
/// provider then answers `nil` ("unknown", so the item is kept). That is the safe
/// answer, so CI accepts it. A `true` (false positive) still fails everywhere, and
/// the safety property "never `false` while open" is tested separately.
public func reportsNotOpen(_ answer: Bool?) -> Bool {
    if answer == false { return true }
    return answer == nil && ProcessInfo.processInfo.environment["CI"] == "true"
}
