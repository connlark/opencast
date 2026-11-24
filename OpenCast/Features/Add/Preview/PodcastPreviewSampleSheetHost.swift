import SwiftUI

struct PodcastPreviewSampleSheetHost<Backdrop: View, Sheet: View>: View {
    @State private var isPresented = false

    let detent: PresentationDetent
    let backdrop: Backdrop
    let sheet: Sheet

    init(detent: PresentationDetent, @ViewBuilder backdrop: () -> Backdrop, @ViewBuilder sheet: () -> Sheet) {
        self.detent = detent
        self.backdrop = backdrop()
        self.sheet = sheet()
    }

    var body: some View {
        backdrop
            .sheet(isPresented: $isPresented) {
                sheet
                    .presentationDetents([detent])
            }
            .onAppear(perform: present)
    }

    // A sheet bound to a constant renders correctly only once per Xcode launch.
    private func present() {
        withTransaction(\.disablesAnimations, true) {
            isPresented = true
        }
    }
}
