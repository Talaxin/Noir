//
//  SoraApp.swift
//  Sora
//
//  Created by Francesco on 12/08/25.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
/// Handles background URLSession completion so downloads can finish when the app was in background.
final class NoirAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == "com.maxtori.noir.downloads" {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}

final class NoirURLOpener: ObservableObject {
    @Published var alertTitle: String = ""
    @Published var alertMessage: String?
    @Published var showAlert: Bool = false

    func handleURL(_ url: URL) {
        guard (url.scheme == "noir" || url.scheme == "sora"), let host = url.host else { return }
        switch host {
        case "trakt-callback":
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                TrackerManager.shared.handleTraktCallback(code: code)
            }
        case "anilist-callback":
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                TrackerManager.shared.handleAniListCallback(code: code)
            }
        case "default_page":
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
               let libraryURL = comps.queryItems?.first(where: { $0.name == "url" })?.value,
               !libraryURL.isEmpty {
                UserDefaults.standard.set(libraryURL, forKey: "lastCommunityURL")
                UserDefaults.standard.set(true, forKey: "didReceiveDefaultPageLink")
                alertTitle = "Module Library Added"
                alertMessage = "You can browse the community library in Settings."
                showAlert = true
            }
        case "module", "service":
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let serviceURL = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  !serviceURL.isEmpty else { return }
            Task { @MainActor in
                let started = await ServiceManager.shared.handlePotentialServiceURL(serviceURL)
                self.alertTitle = started ? "Service Download Started" : "Invalid Link"
                self.alertMessage = started ? "Check Settings > Services for progress." : "The link does not point to a valid service JSON."
                self.showAlert = true
            }
        case "x-callback-url":
            // Infuse (and other x-callback apps) return here when playback finishes. If we opened a download in Infuse, mark it watched.
            if url.path.contains("playbackDidFinish") {
                ProgressManager.shared.takePendingExternalPlaybackAndMarkWatched()
            }
            break
        default:
            break
        }
    }
}
#endif

@main
struct SoraApp: App {
#if !os(tvOS)
    @UIApplicationDelegateAdaptor(NoirAppDelegate.self) private var appDelegate
#endif
    @StateObject private var settings = Settings()
    @StateObject private var moduleManager = ModuleManager.shared
    @StateObject private var favouriteManager = FavouriteManager.shared

#if !os(tvOS)
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    let kanzen = KanzenEngine()
    @StateObject private var urlOpener = NoirURLOpener()
#endif

    init() {
        DispatchQueue.global(qos: .background).async {
            CacheManager.shared.checkAndAutoClearIfNeeded()
        }
        _ = DownloadManager.shared
    }

    var body: some Scene {
        WindowGroup {
#if os(tvOS)
            ContentView()
#else
            rootView
                .onOpenURL { url in
                    urlOpener.handleURL(url)
                }
                .alert(urlOpener.alertTitle, isPresented: $urlOpener.showAlert) {
                    Button("OK") {
                        urlOpener.alertMessage = nil
                        urlOpener.showAlert = false
                    }
                } message: {
                    if let msg = urlOpener.alertMessage {
                        Text(msg)
                    }
                }
#endif
        }
    }

#if !os(tvOS)
    @ViewBuilder
    private var rootView: some View {
        if showKanzen {
            KanzenMenu()
                .environmentObject(settings)
                .environmentObject(moduleManager)
                .environmentObject(favouriteManager)
                .environment(\.managedObjectContext, favouriteManager.container.viewContext)
                .accentColor(settings.accentColor)
        } else {
            ContentView()
        }
    }
#endif
}
