import AuthenticationServices
import WebKit
import CryptoKit

/// Native Sign in with Apple for the iOS app.
/// The web app calls window.webkit.messageHandlers.appleAuth.postMessage({action: 'signIn'})
/// On success, the identity token is passed back to web via JS for Firebase signInWithCredential.
class AppleAuthManager: NSObject {
    static let shared = AppleAuthManager()

    private weak var webView: WKWebView?
    private weak var presentingVC: UIViewController?
    private var currentNonce: String?

    func attach(webView: WKWebView, viewController: UIViewController) {
        self.webView = webView
        self.presentingVC = viewController
    }

    func signIn() {
        let nonce = randomNonceString()
        currentNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    private func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            let randoms = (0..<16).map { _ in UInt8.random(in: 0...255) }
            for r in randoms {
                if remaining == 0 { break }
                if r < charset.count {
                    result.append(charset[Int(r)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func notifyWeb(type: String, idToken: String, nonce: String, fullName: String) {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
             .replacingOccurrences(of: "\n", with: "\\n")
        }
        let js = "window.dispatchEvent(new CustomEvent('faithmap-apple-auth',{detail:{type:'\(type)',idToken:'\(esc(idToken))',nonce:'\(esc(nonce))',fullName:'\(esc(fullName))'}}))"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func handleJSMessage(_ body: [String: Any]) {
        guard let action = body["action"] as? String, action == "signIn" else { return }
        signIn()
    }
}

extension AppleAuthManager: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            notifyWeb(type: "signInFailed", idToken: "", nonce: "", fullName: "")
            return
        }
        var name = ""
        if let given = credential.fullName?.givenName, let family = credential.fullName?.familyName {
            name = "\(given) \(family)"
        }
        notifyWeb(type: "signInSucceeded", idToken: idToken, nonce: nonce, fullName: name)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        notifyWeb(type: "signInFailed", idToken: "", nonce: "", fullName: "")
    }
}

extension AppleAuthManager: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return presentingVC?.view.window ?? UIWindow()
    }
}
