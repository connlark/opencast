import SwiftUI
import WebKit

struct ShowNotesWebView: View {
    let html: String
    @State private var page = ShowNotesWebView.makePage()

    var body: some View {
        WebView(page)
            .task(id: html) {
                page.load(html: wrappedHTML)
            }
    }

    private var wrappedHTML: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body {
              font: -apple-system-body;
              color: \(UIColor.label.cssRGB);
              background: transparent;
              line-height: 1.45;
              margin: 0;
            }
            a { color: \(UIColor.systemBlue.cssRGB); }
            img, iframe { max-width: 100%; height: auto; }
          </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    private static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        return WebPage(configuration: configuration)
    }
}

private extension UIColor {
    var cssRGB: String {
        let resolved = resolvedColor(with: UITraitCollection.current)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return "rgba(\(Int(red * 255)), \(Int(green * 255)), \(Int(blue * 255)), \(alpha))"
    }
}
