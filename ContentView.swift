//
//  ContentView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI

// MARK: - Open Settings Environment (for toolbar gear in Library, Search, Downloads)

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openSettings: () -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

struct ContentView: View {
    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showingSettings = false
    
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            tabView
                .accentColor(accentColorManager.currentAccentColor)
                .environment(\.openSettings, { showingSettings = true })
            
            if showingSettings {
                settingsSheet
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingSettings)
    }
    
    private var tabView: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tag(0)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
            
            ScheduleView()
                .tag(1)
                .tabItem {
                    Image(systemName: "calendar")
                    Text("Schedule")
                }
            
            DownloadsView()
                .tag(2)
                .tabItem {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Downloads")
                }
#if !os(tvOS)
                .badge(downloadManager.activeDownloadCount > 0 ? downloadManager.activeDownloadCount : 0)
#endif
            
            LibraryView()
                .tag(3)
                .tabItem {
                    Image(systemName: "books.vertical.fill")
                    Text("Library")
                }
            
            SearchView()
                .tag(4)
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
        }
    }
    
    private var settingsSheet: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Back") { showingSettings = false }
                            }
                        }
                }
            } else {
                NavigationView {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Back") { showingSettings = false }
                            }
                        }
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
