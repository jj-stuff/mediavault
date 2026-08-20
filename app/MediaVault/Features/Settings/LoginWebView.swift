import SwiftUI
import WebKit

/// Sign-in sheet for the remote server.
///
/// Authentication is a web session on purpose: once the cookie is in
/// `HTTPCookieStorage.shared`, both the app's API calls and AVPlayer's own range
/// requests are authenticated without either one knowing anything about auth.
struct LoginSheetView: View {
    let serverURL: URL

    @Environment(RemoteServerService.self) private var remote
    @Environment(LibraryController.self) private var library
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
                                await remote.checkAuth()
                                // Load immediately on success, so the user lands on a
                                // populated library instead of an empty one.
                                if remote.isAuthenticated { await library.load() }
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
        // The default (persistent) data store, so the session survives app restarts
        // and can be copied into HTTPCookieStorage.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Copies cookies out of the web view after each navigation, so they are in
        /// place by the time the user taps Done.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore
                    .httpCookieStore.allCookies()
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
        }
    }
}
