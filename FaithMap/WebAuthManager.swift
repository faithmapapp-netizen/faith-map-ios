import AuthenticationServices
import WebKit

/// Handles OAuth via system browser (ASWebAuthenticationSession) for providers
/// blocked in WKWebView (Google). Opens the app's auth-callback page which
/// does Firebase popup auth, then captures the custom-scheme redirect.
class WebAuthManager: NSObject {
    private var session: ASWebAuthenticationSession?
    private var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func startOAuth(provider: String) {
        guard let url = URL(string: "https://havenmedia.app/auth-callback?provider=\(provider)") else { return }

        session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "app.havenmedia.faithmap"
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }
            if let error = error {
                self.dispatchResult(provider: provider, idToken: nil, accessToken: nil, error: error.localizedDescription)
                return
            }
            guard let url = callbackURL,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                self.dispatchResult(provider: provider, idToken: nil, accessToken: nil, error: "Invalid callback")
                return
            }

            var idToken: String?
            var accessToken: String?
            var nonce: String?
            for item in components.queryItems ?? [] {
                if item.name == "idToken" { idToken = item.value }
                if item.name == "accessToken" { accessToken = item.value }
                if item.name == "nonce" { nonce = item.value }
            }

            self.dispatchResult(provider: provider, idToken: idToken, accessToken: accessToken, nonce: nonce, error: nil)
        }

        session?.presentationContextProvider = self
        session?.prefersEphemeralWebBrowserSession = false
        session?.start()
    }

    private func dispatchResult(provider: String, idToken: String?, accessToken: String?, nonce: String?, error: String?) {
        var detail: [String: Any] = ["provider": provider]
        if let idToken = idToken { detail["idToken"] = idToken }
        if let accessToken = accessToken { detail["accessToken"] = accessToken }
        if let nonce = nonce { detail["nonce"] = nonce }
        if let error = error { detail["error"] = error }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: detail),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let js = "window.dispatchEvent(new CustomEvent('faithmap-oauth-auth', {detail: \(jsonString)}));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

extension WebAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
