//
//  NoirTheme.swift
//  Noir
//
//  Theme system with customizable gradient colors
//

import SwiftUI

class NoirTheme: ObservableObject {
    static let shared = NoirTheme()
    
    // MARK: - Persisted Settings
    
    @Published var settingsGradientColor: Color {
        didSet { saveColor(settingsGradientColor, key: "noirThemeGradientColor") }
    }
    
    // MARK: - Constants
    
    let cardCornerRadius: CGFloat = 16
    let backgroundBase = Color(red: 0.08, green: 0.08, blue: 0.08)
    let cardBackground = Color.white.opacity(0.08)
    let separatorColor = Color.white.opacity(0.12)
    let sectionHeaderColor = Color.white.opacity(0.5)
    
    // MARK: - Presets
    
    static let gradientPresets: [(name: String, color: Color)] = [
        ("Purple", Color(red: 0.25, green: 0.12, blue: 0.45)),
        ("Blue", Color(red: 0.10, green: 0.15, blue: 0.40)),
        ("Teal", Color(red: 0.08, green: 0.28, blue: 0.30)),
        ("Red", Color(red: 0.38, green: 0.10, blue: 0.12)),
        ("Green", Color(red: 0.10, green: 0.28, blue: 0.14))
    ]
    
    // MARK: - Init
    
    private init() {
        self.settingsGradientColor = Self.gradientPresets[0].color
        self.settingsGradientColor = loadColor(key: "noirThemeGradientColor") ?? Self.gradientPresets[0].color
    }
    
    // MARK: - Persistence
    
    private func saveColor(_ color: Color, key: String) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Silently fail — default will be used next launch
        }
    }
    
    private func loadColor(key: String) -> Color? {
        guard let data = UserDefaults.standard.data(forKey: key),
              !data.isEmpty else { return nil }
        do {
            if let uiColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
                return Color(uiColor)
            }
        } catch { }
        return nil
    }
}

// MARK: - View Modifiers

extension View {
    /// Apply the standard dark base background used across all screens
    func noirBackground() -> some View {
        self.background(NoirTheme.shared.backgroundBase.ignoresSafeArea())
    }
    
    /// Apply the gradient background used in Settings screens
    func noirGradientBackground() -> some View {
        self.modifier(NoirAutoGradientModifier())
    }
    
    /// Hide list/scroll-view chrome (iOS 16+, unavailable on tvOS)
    @ViewBuilder
    func noirHideScrollBackground() -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Dark toolbar color scheme (iOS 16+, unavailable on tvOS)
    @ViewBuilder
    func noirDarkToolbar() -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Apply Noir styling to any List-based settings sub-view:
    /// gradient background, transparent list style, dark toolbar
    func noirSettingsStyle() -> some View {
        self
            .noirHideScrollBackground()
            .noirGradientBackground()
            .noirDarkToolbar()
    }
}

// MARK: - Auto-tracking gradient modifier

private struct NoirAutoGradientModifier: ViewModifier {
    @State private var scrollOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: "noirGradientScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                scrollOffset = value
            }
            .background(
                SettingsGradientBackground(scrollOffset: scrollOffset)
                    .ignoresSafeArea()
            )
    }
}
