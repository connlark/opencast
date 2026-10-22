import SwiftUI

/// The Keep Downloaded choices. A show's picker leads with a Default row,
/// tagged nil, that names the limit the show follows without a choice of
/// its own; the default limit's own picker has no such row.
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
