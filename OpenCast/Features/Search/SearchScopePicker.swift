import SwiftUI

struct SearchScopePicker: View {
    var body: some View {
        ForEach(SearchScope.allCases) { scope in
            Text(scope.title).tag(scope)
        }
    }
}
