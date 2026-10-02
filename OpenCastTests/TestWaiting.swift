import Foundation

/// Polls `condition` on the main actor until it holds or `timeout` passes, and
/// says whether it held.
///
/// The default is long on purpose. A wait returns the moment its condition is
/// true, so a passing test stays fast; a short budget only decides how soon a
/// loaded machine makes the test act before its precondition holds. Pass a
/// short `timeout` only when the test means "this must not take longer", and
/// say why at the call site.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(60),
    pollInterval: Duration = .milliseconds(20),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }

    return condition()
}
