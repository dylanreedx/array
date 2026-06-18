import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

@MainActor
final class BrowserEngineContext {
    private var dataStores: [String: WKWebsiteDataStore] = [:]
    private(set) var webViewCreationCountForQA = 0
    private let inspectionPolicy: BrowserInspectionPolicy

    init(inspectionPolicy: BrowserInspectionPolicy = .resolved()) {
        self.inspectionPolicy = inspectionPolicy
    }

    /// Returns (and lazily caches) the data store for a given storage group id.
    /// `BrowserState.sharedStorageGroupId` maps to `WKWebsiteDataStore.default()`;
    /// any other id is parsed as a UUID and fed to `WKWebsiteDataStore(forIdentifier:)`
    /// (macOS 14+). Falls back to the default store for non-UUID identifiers so
    /// legacy on-disk data does not crash the boot path.
    func dataStore(for storageGroupId: String) -> WKWebsiteDataStore {
        if let cached = dataStores[storageGroupId] { return cached }
        let store: WKWebsiteDataStore
        if storageGroupId == BrowserState.sharedStorageGroupId {
            store = WKWebsiteDataStore.default()
        } else if let uuid = UUID(uuidString: storageGroupId) {
            store = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            fputs("BrowserEngineContext: storage group id '\(storageGroupId)' is not a UUID; falling back to default store\n", stderr)
            store = WKWebsiteDataStore.default()
        }
        dataStores[storageGroupId] = store
        return store
    }

    /// Builds a fresh `WKWebView` bound to the project's data store. WebKit
    /// shares its render process pool internally as of macOS 12+ (WKProcessPool
    /// is a no-op), so we don't need to supply one. The data store enforces
    /// per-project isolation.
    func makeWebView(storageGroupId: String) -> WKWebView {
        webViewCreationCountForQA += 1
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: storageGroupId)
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        inspectionPolicy.apply(to: webView)
        return webView
    }

    /// Drops the data-store cache. Called after every browser runtime has
    /// torn down its web view so WebKit's process tree can fully release.
    func shutdown() {
        dataStores.removeAll()
    }
}
