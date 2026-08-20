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

    @State private var loadFailure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadFailure {
                    failureView(message: loadFailure)
                } else {
                    LoginWebView(url: serverURL, failure: $loadFailure)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
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
                    .disabled(loadFailure != nil)
                }
            }
        }
    }

    /// A failed load used to render as a blank white webview with no explanation,
    /// which is indistinguishable from a server that returned an empty page.
    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Reach the Server", systemImage: "wifi.exclamationmark")
        } description: {
            VStack(spacing: 12) {
                Text(message)
                Text(serverURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } actions: {
            Button("Try Again") { loadFailure = nil }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: URL
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure) }

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
        private let failure: Binding<String?>

        init(failure: Binding<String?>) {
            self.failure = failure
        }

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

        // Both failure callbacks matter: `provisional` covers never reaching the
        // server at all, which is the case that produced a silent white screen.
        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        private func report(_ error: Error) {
            // Cancellation is normal — a redirect supersedes the previous load.
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain
                    && nsError.code == NSURLErrorCancelled) else { return }
            failure.wrappedValue = NetworkErrorMessage.explain(nsError)
        }

    }
}
