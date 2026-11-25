#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import UIKit
import WebKit

struct WebContentView: View {
    let url: String
    let handleAppLink: (URL) -> Bool

    init(url: String, handleAppLink: @escaping (URL) -> Bool = { _ in false }) {
        self.url = url
        self.handleAppLink = handleAppLink
    }

    var body: some View {
        WebViewRepresentable(urlString: url, handleAppLink: handleAppLink)
            .ignoresSafeArea()
    }
}

private struct WebViewRepresentable: UIViewControllerRepresentable {
    let urlString: String
    let handleAppLink: (URL) -> Bool

    func makeUIViewController(context: Context) -> BrowserWindowNavigationController {
        let root = WebViewController(url: URL(string: urlString))
        let windows = BrowserWindowNavigationController(rootViewController: root)
        windows.handleAppLink = handleAppLink
        return windows
    }

    func updateUIViewController(_ controller: BrowserWindowNavigationController, context: Context) {
        controller.handleAppLink = handleAppLink
    }
}

private final class BrowserWindowNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    var handleAppLink: (URL) -> Bool = { _ in false }

    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        interactivePopGestureRecognizer?.delegate = self
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            interactiveContentPopGestureRecognizer?.isEnabled = false
        }
        #endif
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1, transitionCoordinator == nil,
              let window = topViewController as? WebViewController else { return false }
        return window.previousPage == nil
    }
}

final class WebViewController: UIViewController, UIGestureRecognizerDelegate {
    private let entryURL: URL?
    private let webView: WKWebView
    private var loadingObservation: NSKeyValueObservation?
    private var historySwipe: (origin: WKBackForwardListItem, destination: WKBackForwardListItem)?

    convenience init(url: URL?) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        self.init(entryURL: url, configuration: configuration)
    }

    private init(entryURL: URL?, configuration: WKWebViewConfiguration) {
        self.entryURL = entryURL
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.customUserAgent = AppConfiguration.defaultUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(url:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        setUpLoadingOverlay()
        if #available(iOS 27.0, *) {
            // WebKit can animate a full swipe and still leave its history on the original item.
            for edge: UIRectEdge in [.left, .right] {
                let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(finishHistorySwipe(_:)))
                pan.edges = edge
                pan.cancelsTouchesInView = false
                pan.delegate = self
                view.addGestureRecognizer(pan)
            }
        }
        if let entryURL { webView.load(URLRequest(url: entryURL)) }
    }

    private func setUpLoadingOverlay() {
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.isUserInteractionEnabled = false
        view.addSubview(overlay)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        overlay.addSubview(spinner)
        loadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) { webView, _ in
            overlay.isHidden = !webView.isLoading
            if webView.isLoading {
                spinner.startAnimating()
            } else {
                spinner.stopAnimating()
            }
        }
    }

    fileprivate var previousPage: WKBackForwardListItem? {
        webView.backForwardList.backList.last { $0.url.absoluteString != "about:blank" }
    }

    private func destination(for pan: UIScreenEdgePanGestureRecognizer) -> WKBackForwardListItem? {
        let leadingEdge: UIRectEdge = view.effectiveUserInterfaceLayoutDirection == .leftToRight ? .left : .right
        return pan.edges == leadingEdge ? previousPage : webView.backForwardList.forwardItem
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer else { return false }
        return destination(for: pan) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func finishHistorySwipe(_ pan: UIScreenEdgePanGestureRecognizer) {
        switch pan.state {
        case .began:
            if let origin = webView.backForwardList.currentItem, let target = destination(for: pan) {
                historySwipe = (origin, target)
            }
        case .ended:
            let direction: CGFloat = pan.edges == .left ? 1 : -1
            let travel = direction * pan.translation(in: view).x
            let velocity = direction * pan.velocity(in: view).x
            guard let swipe = historySwipe else { return }
            historySwipe = nil
            guard velocity >= 0, travel > view.bounds.width / 2 || (travel > 30 && velocity > 750) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.webView.isLoading, self.webView.backForwardList.currentItem === swipe.origin,
                      self.destination(for: pan) === swipe.destination else { return }
                self.webView.go(to: swipe.destination)
            }
        case .cancelled:
            historySwipe = nil
        default:
            break
        }
    }

}

extension WebViewController: WKNavigationDelegate {
    private func handleNavigation(_ action: WKNavigationAction) -> Bool {
        guard let url = action.request.url else { return false }
        if action.sourceFrame.isMainFrame, action.targetFrame?.isMainFrame != false,
           (action.navigationType == .linkActivated || action.targetFrame == nil),
           (navigationController as? BrowserWindowNavigationController)?.handleAppLink(url) == true {
            return true
        }
        return openExternalLink(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if handleNavigation(navigationAction) {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard navigationController?.topViewController === self, presentedViewController == nil else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler()
        })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard navigationController?.topViewController === self, presentedViewController == nil else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completionHandler(false)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(true)
        })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, !handleNavigation(action),
              let navigationController, navigationController.topViewController === self,
              presentedViewController == nil else { return nil }
        // WebKit loads the original request and connects this window to its opener.
        let child = WebViewController(entryURL: nil, configuration: configuration)
        navigationController.pushViewController(child, animated: false)
        return child.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let navigationController, navigationController.viewControllers.first !== self else { return }
        if navigationController.topViewController === self {
            navigationController.popViewController(animated: true)
        } else {
            let remaining = navigationController.viewControllers.filter { $0 !== self }
            navigationController.setViewControllers(remaining, animated: false)
        }
    }
}

struct WebContentFlowView: View {
    @State private var mode: DisplayMode = .loading
    @State private var contentURL: String?

    init() {}

    var body: some View {
        Group {
            switch mode {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .webContent:
                if let url = contentURL {
                    WebContentView(url: url)
                } else {
                    Text(verbatim: "Content unavailable")
                        .foregroundStyle(.secondary)
                }
            case .nativeInterface:
                Text(verbatim: "Native interface")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await MainActor.run {
                AppRouter.shared.determineInitialRoute { newMode, url in
                    Task { @MainActor in
                        mode = newMode
                        contentURL = url
                    }
                }
            }
        }
    }
}

#endif
