import SwiftUI

struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let text):
            HelpHeadingBlockView(text: text)
        case .paragraph(let text):
            HelpParagraphBlockView(text: text)
        case .bullets(let items):
            HelpBulletsBlockView(items: items)
        case .callout(let symbol, let title, let text):
            HelpCalloutBlockView(symbol: symbol, title: title, text: text)
        case .link(let title, let url):
            HelpLinkBlockView(title: title, url: url)
        case .unsupported:
            EmptyView()
        }
    }
}
