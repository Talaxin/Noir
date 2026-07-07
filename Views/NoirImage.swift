//
//  NoirImage.swift
//  Noir
//
//  On simulator uses AsyncImage to avoid Kingfisher URLSession (iOS 26 EXC_BREAKPOINT).
//  On device uses KFImage for caching and placeholders.
//

import SwiftUI

#if !targetEnvironment(simulator)
import Kingfisher
#endif

struct NoirImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder = { Color.gray.opacity(0.3) }) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        #if targetEnvironment(simulator)
        if let url = url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder()
                case .success(let image):
                    image.resizable()
                case .failure:
                    placeholder()
                @unknown default:
                    placeholder()
                }
            }
        } else {
            placeholder()
        }
        #else
        KFImage(url)
            .placeholder(placeholder)
            .resizable()
        #endif
    }
}

extension NoirImage {
    /// Passthrough so callers can chain .resizable(); content is already resizable.
    func resizable() -> some View {
        self
    }
    /// Passthrough for KFImage-style API (equivalent to .aspectRatio(contentMode: .fill)).
    func scaledToFill() -> some View {
        self.aspectRatio(contentMode: .fill)
    }
}

extension NoirImage where Placeholder == Color {
    init(url: URL?) {
        self.url = url
        self.placeholder = { Color.gray.opacity(0.3) }
    }
}
