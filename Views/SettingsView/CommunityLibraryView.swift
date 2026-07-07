//
//  CommunityLibraryView.swift
//  Noir
//

#if !os(tvOS)
import SwiftUI
import WebKit

struct CommunityLibraryView: View {
    @AppStorage("lastCommunityURL") private var inputURL: String = ""
    @StateObject private var serviceManager = ServiceManager.shared
    @State private var webURL: URL?
    @State private var errorMessage: String?
    @State private var serviceAddAlertTitle: String?
    @State private var serviceAddAlertMessage: String?
    @State private var showServiceAddAlert = false

    var body: some View {
        VStack(spacing: 0) {
            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
#if targetEnvironment(simulator)
            simulatorPlaceholder
#else
            CommunityWebView(url: webURL) { linkURL in
                handleServiceLink(linkURL)
            }
            .ignoresSafeArea(edges: .top)
#endif
        }
        .onAppear {
            loadURL()
        }
        .alert(serviceAddAlertTitle ?? "Service", isPresented: $showServiceAddAlert) {
            Button("OK") {
                serviceAddAlertTitle = nil
                serviceAddAlertMessage = nil
            }
        } message: {
            if let msg = serviceAddAlertMessage {
                Text(msg)
            }
        }
    }

    #if targetEnvironment(simulator)
    private var simulatorPlaceholder: some View {
        VStack(spacing: 16) {
            Text("Community Library")
                .font(.title2)
                .fontWeight(.semibold)
            Text("The in-app browser is disabled in the simulator. Open the library in Safari:")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let u = webURL {
                Link(u.absoluteString, destination: u)
                    .font(.footnote)
                    .lineLimit(2)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    #endif

    private func loadURL() {
        var s = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "https://" + s
        }
        inputURL = s
        if let u = URL(string: s) {
            webURL = u
            errorMessage = nil
        } else {
            webURL = nil
            errorMessage = "Invalid URL"
        }
    }

    private func handleServiceLink(_ linkURL: URL) {
        guard (linkURL.scheme == "noir" || linkURL.scheme == "sora"),
              linkURL.host == "module" || linkURL.host == "service",
              let comps = URLComponents(url: linkURL, resolvingAgainstBaseURL: false),
              let serviceURL = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              !serviceURL.isEmpty else { return }

        Task { @MainActor in
            let started = await serviceManager.handlePotentialServiceURL(serviceURL)
            serviceAddAlertTitle = started ? "Service Download Started" : "Invalid Link"
            serviceAddAlertMessage = started
                ? "Check Services for progress."
                : "The link does not point to a valid service JSON."
            showServiceAddAlert = true
        }
    }
}

private struct CommunityWebView: UIViewRepresentable {
    let url: URL?
    let onCustomScheme: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCustom: onCustomScheme)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            config.preferences.javaScriptEnabled = true
        }
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let u = url {
            uiView.load(URLRequest(url: u))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onCustom: (URL) -> Void
        init(onCustom: @escaping (URL) -> Void) { self.onCustom = onCustom }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = action.request.url,
               (url.scheme == "noir" || url.scheme == "sora"),
               url.host == "module" || url.host == "service" {
                onCustom(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
#endif
