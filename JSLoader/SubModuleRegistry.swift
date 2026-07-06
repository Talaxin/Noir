//
//  SubModuleRegistry.swift
//  Noir
//
//  Isolated eval + cached extractStreamUrl for aggregator modules (e.g. Checkmate).
//

import JavaScriptCore

final class SubModuleRegistry {
    static let shared = SubModuleRegistry()

    private var extractors: [ObjectIdentifier: [String: JSValue]] = [:]
    private let lock = NSLock()

    func prepare(context: JSContext) {
        lock.lock()
        extractors[ObjectIdentifier(context)] = [:]
        lock.unlock()
        context.installSubModuleBridge(registry: self)
    }

    func store(extractor: JSValue, name: String, in context: JSContext) {
        lock.lock()
        let key = ObjectIdentifier(context)
        var map = extractors[key] ?? [:]
        map[name] = extractor
        extractors[key] = map
        lock.unlock()
    }

    func extractor(named name: String, in context: JSContext) -> JSValue? {
        lock.lock()
        defer { lock.unlock() }
        return extractors[ObjectIdentifier(context)]?[name]
    }

    func clear(context: JSContext) {
        lock.lock()
        extractors.removeValue(forKey: ObjectIdentifier(context))
        lock.unlock()
    }
}

extension JSContext {
    fileprivate func installSubModuleBridge(registry: SubModuleRegistry) {
        let ctx = self

        let registerBlock: @convention(block) (String, String, JSValue, JSValue) -> Void = { name, code, resolve, reject in
            let wrapped = """
            (function(soraFetch, fetchv2, fetch) {
            \(code)
            return { extractStreamUrl: extractStreamUrl };
            })(soraFetch, fetchv2, fetch);
            """
            guard let result = ctx.evaluateScript(wrapped) else {
                let message = ctx.exception?.toString() ?? "Submodule eval failed"
                Logger.shared.log("noirRegisterModule(\(name)): \(message)", type: "Error")
                reject.call(withArguments: [message])
                return
            }
            if let exception = ctx.exception {
                Logger.shared.log("noirRegisterModule(\(name)) exception: \(exception)", type: "Error")
            }
            guard let fn = result.objectForKeyedSubscript("extractStreamUrl"), !fn.isUndefined else {
                Logger.shared.log("noirRegisterModule(\(name)): missing extractStreamUrl", type: "Error")
                reject.call(withArguments: ["missing extractStreamUrl"])
                return
            }
            registry.store(extractor: fn, name: name, in: ctx)
            resolve.call(withArguments: [true])
        }

        let extractBlock: @convention(block) (String, String, JSValue, JSValue) -> Void = { name, episodeID, resolve, reject in
            guard let fn = registry.extractor(named: name, in: ctx) else {
                reject.call(withArguments: ["Submodule not loaded: \(name)"])
                return
            }
            guard let promise = fn.call(withArguments: [episodeID]) else {
                reject.call(withArguments: ["extractStreamUrl did not return a Promise"])
                return
            }
            let then: @convention(block) (JSValue) -> Void = { result in
                resolve.call(withArguments: [result])
            }
            let catchFn: @convention(block) (JSValue) -> Void = { error in
                reject.call(withArguments: [error.toString() ?? "Submodule stream error"])
            }
            promise.invokeMethod("then", withArguments: [JSValue(object: then, in: ctx) as Any])
            promise.invokeMethod("catch", withArguments: [JSValue(object: catchFn, in: ctx) as Any])
        }

        setObject(registerBlock, forKeyedSubscript: "noirRegisterModule" as NSString)
        setObject(extractBlock, forKeyedSubscript: "noirModuleExtract" as NSString)
    }
}
