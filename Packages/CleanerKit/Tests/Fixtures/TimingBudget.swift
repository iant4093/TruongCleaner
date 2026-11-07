import Foundation

/// A time limit for tests that assert promptness (cancellation, timeouts).
///
/// Locally the limit is the stated budget. On slow shared runners other tests
/// compete for the same few cores, so CI sets `TC_TIMING_SLACK` (for example
/// `10`) to scale every budget. The budget in the source stays the product
/// requirement; the slack only widens the check, never the requirement.
public func timingBudget(_ budget: Duration) -> Duration {
    let raw = ProcessInfo.processInfo.environment["TC_TIMING_SLACK"] ?? ""
    guard let slack = Int(raw), slack > 1 else { return budget }
    return budget * slack
}
