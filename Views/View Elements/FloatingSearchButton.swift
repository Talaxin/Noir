//
//  FloatingSettingsButton.swift
//  Noir
//
//  Created on 27/02/26.
//

import SwiftUI

/// Same settings gear icon used everywhere (toolbar and floating).
private let settingsGearFont = Font.system(size: 20, weight: .medium)

struct FloatingSettingsButton: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        Button(action: {
            isPresented = true
        }) {
            Image(systemName: "gear")
                .font(settingsGearFont)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .applyLiquidGlassBackground(cornerRadius: 22)
        }
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

/// Reusable settings gear for toolbar items — same icon as floating button.
struct SettingsGearIcon: View {
    var body: some View {
        Image(systemName: "gear")
            .font(settingsGearFont)
    }
}

struct FloatingSettingsOverlay: View {
    @Binding var showingSettings: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .allowsHitTesting(false)
                FloatingSettingsButton(isPresented: $showingSettings)
                    .padding(.trailing, 16)
                    .padding(.top, geometry.safeAreaInsets.top + 8)
            }
        }
    }
}
