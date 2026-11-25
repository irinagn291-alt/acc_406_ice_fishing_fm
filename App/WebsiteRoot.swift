import SwiftUI

@MainActor
struct WebsiteRoot<Native: View>: View {
    let registrationHost: String
    @ViewBuilder let native: () -> Native

    private enum Route {
        case loading, native, web(URL)
    }

    @State private var route: Route = .loading

    var body: some View {
        Group {
            switch route {
            case .loading:
                ProgressView().task { resolveRoute() }
            case .native:
                native()
            case .web(let url):
                WebContentView(url: url.absoluteString, handleAppLink: openNativeLink)
                    .preferredColorScheme(.dark)
            }
        }
        .onOpenURL { _ = openNativeLink($0) }
    }

    private func resolveRoute() {
        guard case .loading = route else { return }
        AppConfiguration.configure(host: registrationHost)
        AppRouter.shared.determineInitialRoute { mode, address in
            guard case .loading = route else { return }
            guard mode == .webContent else {
                route = .native
                return
            }
            guard let url = Self.contentURL(address) else {
                DataCache.shared.clearCache()
                route = .native
                return
            }
            route = .web(url)
        }
    }

    private static func contentURL(_ address: String?) -> URL? {
        guard let raw = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("/") else { return nil }
        let absolute = URLComponents(string: raw)?.scheme == nil ? "https://\(raw)" : raw
        guard let url = URL(string: absolute), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func openNativeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              let type = types.first(where: { $0["CFBundleURLName"] as? String == "Native navigation" }),
              let schemes = type["CFBundleURLSchemes"] as? [String],
              schemes.contains(scheme) else { return false }
        if url.host?.lowercased() == "native", url.path.isEmpty || url.path == "/",
           url.user == nil, url.password == nil, url.port == nil {
            route = .native
        }
        return true
    }
}
