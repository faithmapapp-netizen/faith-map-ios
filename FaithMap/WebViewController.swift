import UIKit
import WebKit

/// Faith Map iOS wrapper — WKWebView loading the production web app.
/// No browser chrome: installs with app icon and splash, feels native.
/// Includes StoreKit 2 bridge for native Apple in-app purchases.
class WebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!

    // Production URL — v2 app entry
    private let appURL = URL(string: "https://havenmedia.app/?view=learn")!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Enable local storage / IndexedDB for offline progress
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // StoreKit JS bridge — web app calls window.webkit.messageHandlers.storekit.postMessage(...)
        config.userContentController.add(self, name: "storekit")
        // Native Apple Sign-In bridge — web app calls window.webkit.messageHandlers.appleAuth.postMessage(...)
        config.userContentController.add(self, name: "appleAuth")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        view = webView

        if #available(iOS 15.0, *) {
            StoreKitManager.shared.attach(webView: webView)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppleAuthManager.shared.attach(webView: webView, viewController: self)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "storekit" {
            if #available(iOS 15.0, *) {
                StoreKitManager.shared.handleJSMessage(body)
            }
        } else if message.name == "appleAuth" {
            AppleAuthManager.shared.handleJSMessage(body)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: appURL))
    }

    // Keep navigation inside the app for faith-map domains; open externals in Safari
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let host = url.host {
            if host.contains("havenmedia.app") || host.contains("havenmedia.workers.dev") {
                decisionHandler(.allow)
                return
            }
            // External links (Stripe checkout, etc.) open in Safari
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}
