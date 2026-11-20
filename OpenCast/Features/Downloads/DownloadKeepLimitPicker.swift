import SwiftUI

struct DownloadKeepLimitPicker: View {
    @Binding var selection: DownloadKeepLimit?
    /// The default a show's Default row follows; nil leaves the row out.
    var followedDefault: DownloadKeepLimit?

    var body: some View {
        Picker("Keep Downloaded", selection: $selection) {
            if let followedDefault {
                Text("Default (\(followedDefault.title))")
                    .tag(DownloadKeepLimit?.none)
                Divider()
            }
            ForEach(DownloadKeepLimit.allCases) { keepLimit in
                Text(keepLimit.title)
                    .tag(Optional(keepLimit))
            }
        }
    }
}
