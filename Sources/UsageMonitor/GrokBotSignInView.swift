import SwiftUI
import WebKit

/// Each sheet owns a fresh, nonpersistent WebKit store. No browser or app cookies are imported.
struct GrokBotSignInView: View {
    let save: (ConnectionSecrets, AccountIdentity) throws -> Void
    let finish: () -> Void
    @State private var browser = PrivateSignInBrowser()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Grok Bot").font(.title2.bold())
            Text("Use the account for Grok Bot. This private window does not use your other browser logins.")
                .font(.callout).foregroundStyle(.secondary)
            PrivateSignInWebView(browser: browser).frame(height: 480)
            if let error { UsageWarning(message: error) }
            Text("If sign-in is blocked here, cancel and use the manual session Cookie field.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { ProgressView().controlSize(.small); Text("Waiting for sign-in…"); Spacer(); Button("Cancel", action: finish) }
        }.padding(20).frame(width: 620)
        .task {
            var attempted: String?
            while !Task.isCancelled {
                let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                // Only session cookies applicable to the fixed cursor.com API are considered.
                let names = ["WorkosCursorSessionToken", "__Secure-next-auth.session-token", "next-auth.session-token", "wos-session", "__Secure-authjs.session-token"]
                let selected = cookies.filter {
                    names.contains($0.name) && ["cursor.com", ".cursor.com"].contains($0.domain)
                    && !$0.value.isEmpty && $0.value.utf8.count < 16384
                }
                let cookie = selected.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if !cookie.isEmpty, cookie != attempted {
                    attempted = cookie
                    do {
                        let secrets = ConnectionSecrets(key: cookie)
                        let snapshot = try await GrokBotClient().fetch(Account(label: "", provider: .cursor), secrets: secrets)
                        try Task.checkCancellation()
                        guard let identity = snapshot.identity else { throw MonitorError.invalidResponse }
                        try save(secrets, identity)
                        finish()
                        return
                    } catch is CancellationError { return }
                    catch { self.error = (error as? MonitorError)?.localizedDescription ?? "Could not verify this session." }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onDisappear { browser.webView.stopLoading() }
    }
}

@MainActor final class PrivateSignInBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == "https" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }
}

private struct PrivateSignInWebView: NSViewRepresentable {
    let browser: PrivateSignInBrowser
    func makeNSView(context: Context) -> WKWebView {
        browser.webView.load(URLRequest(url: URL(string: "https://authenticator.cursor.sh")!))
        return browser.webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
