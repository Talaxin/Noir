//
//  JSController.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import JavaScriptCore

class JSController: NSObject, ObservableObject {
    static let shared = JSController()
    var context: JSContext
    /// When set, Checkmate (and similar) modules can push partial stream lists before the final Promise resolves.
    var streamProgressHandler: (([String]?, [String]?, [[String: Any]]?) -> Void)?
    
    override init() {
        self.context = JSContext()
        super.init()
        setupContext()
    }
    
    func setupContext() {
        context.setupJavaScriptEnvironment()
        SubModuleRegistry.shared.prepare(context: context)
        bindStreamProgressBridge()
    }
    
    func loadScript(_ script: String) {
        context = JSContext()
        context.setupJavaScriptEnvironment()
        SubModuleRegistry.shared.prepare(context: context)
        bindStreamProgressBridge()
        context.evaluateScript(script)
        if let exception = context.exception {
            Logger.shared.log("Error loading script: \(exception)", type: "Error")
        }
    }

    private func bindStreamProgressBridge() {
        let block: @convention(block) (String) -> Void = { [weak self] jsonString in
            guard let self, let handler = self.streamProgressHandler else { return }
            guard let parsed = Self.parseStreamJSONString(jsonString) else { return }
            DispatchQueue.main.async {
                handler(parsed.streams, parsed.subtitles, parsed.sources)
            }
        }
        context.setObject(block, forKeyedSubscript: "noirOnStreamsProgress" as NSString)
    }
}
