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
        // OAuth via system browser — web app calls window.webkit.messageHandlers.oauthAuth.postMessage(...)
        config.userContentController.add(self, name: "oauthAuth")
        // Local notifications bridge — web app calls window.webkit.messageHandlers.notifications.postMessage(...)
        config.userContentController.add(self, name: "notifications")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        view = webView

        if #available(iOS 15.0, *) {
            StoreKitManager.shared.attach(webView: webView)
        }
        NotificationManager.shared.attach(webView: webView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppleAuthManager.shared.attach(webView: webView, viewController: self)
    }

    // MARK: - WKScriptMessageHandler

    private var webAuthManager: WebAuthManager?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "storekit" {
            if #available(iOS 15.0, *) {
                StoreKitManager.shared.handleJSMessage(body)
            }
        } else if message.name == "appleAuth" {
            AppleAuthManager.shared.handleJSMessage(body)
        } else if message.name == "notifications" {
            NotificationManager.shared.handleJSMessage(body)
        } else if message.name == "oauthAuth" {
            let provider = body["provider"] as? String ?? "google"
            if webAuthManager == nil {
                webAuthManager = WebAuthManager(webView: webView)
            }
            webAuthManager?.startOAuth(provider: provider)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Build 12 — poster launch hold (cold start only, see showLaunchSplash).
        showLaunchSplash()
        // The web view loads underneath the splash — the hold never delays it.
        webView.load(URLRequest(url: appURL))
    }

    // MARK: - Launch poster hold (Build 12)

    /// Minimum time the poster stays up on cold start.
    private let splashMinDuration: TimeInterval = 3.0
    /// Hard cap: a slow network must never trap the user behind the poster.
    private let splashMaxDuration: TimeInterval = 5.0
    private var splashOverlay: UIView?
    private var splashMinElapsed = false
    private var splashLoadFinished = false
    private var splashDismissed = false

    /// Presents the same LaunchPoster treatment as LaunchScreen.storyboard
    /// (composed poster image, aspect-fit, on the poster's sky tone #1A4C79)
    /// above the web view, so the transition from the system launch screen is
    /// seamless. Runs once from viewDidLoad — this controller is created once
    /// per scene connection, i.e. cold start only: returning from the
    /// background or navigating inside the app never re-shows the poster.
    private func showLaunchSplash() {
        let overlay = UIView(frame: webView.bounds)
        overlay.backgroundColor = UIColor(red: 26.0 / 255.0, green: 76.0 / 255.0, blue: 121.0 / 255.0, alpha: 1.0)
        let imageView = UIImageView(image: UIImage(named: "LaunchPoster"))
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: overlay.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
        ])
        overlay.translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: webView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
        ])
        splashOverlay = overlay

        // Minimum-hold gate: after 3s, dismissal only waits on the first load.
        DispatchQueue.main.asyncAfter(deadline: .now() + splashMinDuration) { [weak self] in
            self?.splashMinElapsed = true
            self?.dismissLaunchSplashIfReady()
        }
        // Hard cap: dismiss at 5s even if the first load is still pending.
        DispatchQueue.main.asyncAfter(deadline: .now() + splashMaxDuration) { [weak self] in
            self?.dismissLaunchSplash()
        }
    }

    private func dismissLaunchSplashIfReady() {
        guard splashMinElapsed, splashLoadFinished else { return }
        dismissLaunchSplash()
    }

    private func dismissLaunchSplash() {
        guard !splashDismissed, let overlay = splashOverlay else { return }
        splashDismissed = true
        splashOverlay = nil
        if UIAccessibility.isReduceMotionEnabled {
            overlay.removeFromSuperview()
        } else {
            UIView.animate(withDuration: 0.35, animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.removeFromSuperview()
            })
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        splashLoadFinished = true
        dismissLaunchSplashIfReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A failed first load also ends the wait (the 3s minimum still applies);
        // the user then sees the web view's own state instead of the poster.
        splashLoadFinished = true
        dismissLaunchSplashIfReady()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        splashLoadFinished = true
        dismissLaunchSplashIfReady()
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
