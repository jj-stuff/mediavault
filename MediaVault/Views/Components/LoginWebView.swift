import SwiftUI
import WebKit

/// Full-screen web view for signing into the remote server.
/// After the user taps Done, cookies are synced from WKWebView to URLSession's
/// shared HTTPCookieStorage so all subsequent API calls and AVPlayer requests
/// are automatically authenticated.
struct LoginSheetView: View {
    let serverURL: URL
    @Environment(RemoteServerService.self) private var remoteService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView(url: serverURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task {
                                await remoteService.checkAuth()
                                dismiss()
                            }
                        }
                    }
                }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        // Use the default (persistent) website data store so cookies
        // survive app restarts and can be synced to HTTPCookieStorage.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// After each page finishes loading, push all WKWebView cookies into
        /// URLSession's shared storage so API calls pick them up automatically.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
        }
    }
}
