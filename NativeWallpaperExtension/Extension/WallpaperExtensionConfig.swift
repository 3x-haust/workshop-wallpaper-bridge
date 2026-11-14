import ExtensionFoundation
import Foundation

struct WallpaperExtensionConfig: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        traceLog("XPC from PID=\(connection.processIdentifier)")

        // Validate the caller before building interfaces, exporting the handler,
        // or resuming — an unexpected (non-Apple) process never reaches our
        // exported methods.
        guard CallerValidation.isAcceptable(connection) else {
            extensionLog("XPC rejected: untrusted caller")
            return false
        }

        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)

        // Build class whitelist from runtime-loaded WallpaperExtensionKit classes
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]

        let allTypes = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            } else {
                missing.append(name)
            }
        }
        if !missing.isEmpty {
            extensionLog("  MISSING types: \(missing.joined(separator: ", "))")
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>

        let selectors: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]

        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: (any WallpaperExtensionProxyXPCProtocol).self)

        let handler = WallpaperXPCHandler()
        handler.connectionPID = connection.processIdentifier
        connection.exportedObject = handler

        let agentProxy = connection.remoteObjectProxy
            as? (any WallpaperExtensionProxyXPCProtocol)
        let snapshotInvalidationToken = agentProxy.map {
            WallpaperSnapshotInvalidator.shared.register($0)
        }

        connection.interruptionHandler = { traceLog("XPC interrupted") }
        connection.invalidationHandler = { [weak handler] in
            WallpaperSnapshotInvalidator.shared.unregister(
                snapshotInvalidationToken
            )
            guard let handler else { extensionLog("XPC invalidated (handler gone)"); return }
            handler.agentProxy = nil
            let pid = handler.connectionPID

            // Context-reuse model: DO NOT tear down contexts on connection drop.
            // Every wallpaper pick (and idle transition) drops the connection holding
            // the current render and re-acquires ~1s later. Our contexts are keyed by
            // display slot (not by connection) and outlive the connection, so the
            // re-acquire reuses the SAME CAContext (returns the same contextId) — the
            // Agent never drops its host, so there's no gray gap and no exit/recovery
            // is needed. A destroy-on-drop is exactly what caused issue #13 (a routine
            // preview/thumbnail disconnect killing the live wallpaper) and the
            // escalating gray. Contexts are only freed when their video is removed
            // (`removeChoiceRequest`); a genuinely idle process is suspended by
            // RunningBoard, which pauses the renderers at no cost.
            traceLog("XPC invalidated (pid: \(pid)) — kept \(WallpaperState.shared.activeContextCount) context(s) for reuse")
        }

        // Publish the proxy before resuming so an early incoming callback can't
        // observe a nil agentProxy (and skip its invalidateSnapshots).
        handler.agentProxy = agentProxy

        connection.resume()

        traceLog("XPC accepted with full protocol")
        return true
    }
}
