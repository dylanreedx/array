import Foundation
import Security

/// Passkeys (WebAuthn) in browser tiles.
///
/// WKWebView runs a page's `navigator.credentials` call through
/// AuthenticationServices inside Array's own process. For any site that is not
/// one of the app's associated domains, the system answers only when the app's
/// signature carries Apple's managed browser entitlement below; without it the
/// page gets `NotAllowedError` and the sign-in stalls at the passkey step.
/// Apple grants the entitlement to web browsers on request (Account Holder,
/// https://developer.apple.com/contact/request/macos-browsers-passkeys/), and
/// it only takes effect with an embedded provisioning profile that grants it.
/// Until a release carries it, tiles watch for that failure and explain it.
enum BrowserPasskeySupport {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// Whether this process's signature carries the browser passkey
    /// entitlement. Dev and ad-hoc builds never do.
    static let processIsEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool) == true
    }()

    static let failureMessageKind = "passkey-unavailable"

    /// Wraps `navigator.credentials.get/create`. A modal WebAuthn request that
    /// rejects with `NotAllowedError` posts one message to `handlerName`; the
    /// page still receives the original rejection. Conditional (autofill)
    /// requests and non-WebAuthn credential calls are left alone.
    static func failureWatchScript(handlerName: String) -> String {
        """
        (function() {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers['\(handlerName)'];
          const credentials = navigator.credentials;
          if (!handler || !credentials || window.__arrayPasskeyWatchInstalled) return;
          window.__arrayPasskeyWatchInstalled = true;
          for (const operation of ['get', 'create']) {
            const original = credentials[operation];
            if (typeof original !== 'function') continue;
            credentials[operation] = function(options) {
              const pending = original.apply(this, arguments);
              if (!options || !options.publicKey || options.mediation === 'conditional') return pending;
              return pending.catch(function(error) {
                if (error && error.name === 'NotAllowedError') {
                  try { handler.postMessage({ kind: '\(failureMessageKind)', operation: operation, href: location.href }); } catch (_) {}
                }
                throw error;
              });
            };
          }
        })();
        """
    }
}
