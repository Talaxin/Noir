//
//  PlayerPreset.swift
//  test
//
//  Created by Francesco on 28/09/25.
//

import Foundation

struct PlayerPreset: Hashable {
    struct Stream: Hashable {
        enum Source: Hashable {
            case remote(URL)
            case bundled(resource: String, withExtension: String)
        }
        
        let source: Source
        let note: String
        
        func resolveURL() -> URL? {
            switch source {
            case .remote(let url):
                return url
            case .bundled(let resource, let ext):
                return Bundle.main.url(forResource: resource, withExtension: ext)
            }
        }
    }
    
    let title: String
    let summary: String
    let stream: Stream?
    let commands: [[String]]
    
    static var presets: [PlayerPreset] {
        let list: [PlayerPreset] = []
        return list
    }
}
