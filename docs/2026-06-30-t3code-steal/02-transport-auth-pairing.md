# Stealing from t3code: transport channel + auth / pairing / scopes

Status: **research / extraction — 2026-06-30.** For a *future implementing agent*. This
documents how `pingdotgg/t3code` secures its client↔server channel and pairs a new
device, then maps it onto Continuum's `docs/38` Decision D (remote) and E (sync/iOS).

**Area owned by this doc:** the transport channel and *how a new device securely
connects and what it's allowed to do* — the single authed WebSocket, the short-lived
WS ticket, one-time pairing tokens + token exchange, per-RPC capability scopes, DPoP
binding, and secret storage. **Not** owned here: how you physically reach the box
(SSH/tailscale/tunnel — agent #1) and reconnect/backoff (agent #5).

All `file:line` refer to the clone at
`…/scratchpad/t3code/`. Verified = I read the code. Inferred = reasoned from it, flagged.

> **Reading note for the t3code side.** t3code is TS + Effect. The code is dense with
> Effect combinators; the *mechanism* is simple and is what transfers. Snippets below
> are trimmed to the load-bearing lines. Continuum keeps native ghostty + a spatial
> canvas + offline-first, so we steal **patterns**, not the stack.

---

## 0. TL;DR — the shape

t3code is a "web GUI for coding agents": thin clients (browser, Electron desktop,
React-Native mobile) talk to a per-machine server over **exactly one authenticated
WebSocket** carrying **typed Effect-RPC** (JSON-serialized). Both request/response
calls and server-push **streams** ride that one socket. Every RPC method is gated by a
**capability scope**; the session's granted scopes are baked into a signed token at
issue time and checked per-call.

A device joins by exchanging a **one-time pairing token** (12 chars, 5-min TTL,
SQLite-backed, single-use) for a **scoped bearer session** (RFC-8693 token exchange).
Because a browser can't set an `Authorization` header on a WebSocket upgrade, the client
first calls an HTTP endpoint to mint a **short-lived `wsTicket`** (5-min, HMAC-signed)
and passes it as a `?wsTicket=` query param on the `/ws` URL; the server verifies it on
upgrade. Optional **DPoP** binds a token to a client-held P-256 key with per-proof
replay protection. Server secrets are plaintext files, `0600`, atomic-written.

The whole thing is one clean idea: **authenticate the connection, then authorize every
message against a scope set carried in the token.**

---

## 1. What t3code does (grounded, file:line)

### 1.1 One WebSocket carrying typed RPC

The entire live API is a single route, `GET /ws`, that upgrades to a WebSocket whose
frames are Effect-RPC messages. `apps/server/src/ws.ts:1793`:

```ts
// apps/server/src/ws.ts  (websocketRpcRouteLayer, trimmed)
HttpRouter.add("GET", "/ws", Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest;
  const serverAuth = yield* EnvironmentAuth.EnvironmentAuth;
  const sessions = yield* SessionStore.SessionStore;

  // (A) AUTHENTICATE THE UPGRADE — see §1.2
  const session = yield* serverAuth.authenticateWebSocketUpgrade(request).pipe(
    Effect.catchIf(EnvironmentAuth.isServerAuthCredentialError, (e) =>
      failEnvironmentAuthInvalid(EnvironmentAuth.serverAuthCredentialReason(e))),
    Effect.catchIf(EnvironmentAuth.isServerAuthInternalError, (e) =>
      failEnvironmentInternal("internal_error", e)),
  );

  // (B) TURN THE RPC GROUP INTO A WEBSOCKET HANDLER, JSON-serialized.
  //     makeWsRpcLayer(session,…) closes over the authenticated session so every
  //     handler can see `currentSession.scopes` (see §1.4).
  const rpcWebSocketHttpEffect = yield* RpcServer.toHttpEffectWebsocket(WsRpcGroup, {
    disableTracing: true,
  }).pipe(Effect.provide(
    makeWsRpcLayer(session, previewAutomationBroker).pipe(
      Layer.provideMerge(RpcSerialization.layerJson),   // ← JSON on the wire
      /* …service layers… */
    )));

  // (C) track connect/disconnect for the session for the socket's lifetime
  return yield* Effect.acquireUseRelease(
    sessions.markConnected(session.sessionId),
    () => rpcWebSocketHttpEffect,
    () => sessions.markDisconnected(session.sessionId),
  );
}))
```

The contract (`WsRpcGroup`) is an Effect `RpcGroup.make(...)` of ~60 methods
(`packages/contracts/src/rpc.ts:684`). **Streams ride the same socket** by declaring
`stream: true` on the RPC — no second channel:

```ts
// packages/contracts/src/rpc.ts:487  — a streaming RPC
export const WsTerminalAttachRpc = Rpc.make(WS_METHODS.terminalAttach, {
  payload: TerminalAttachInput,
  success: TerminalAttachStreamEvent,                              // element type of the stream
  error: Schema.Union([TerminalError, EnvironmentAuthorizationError]),
  stream: true,                                                    // ← server-push over the SAME ws
});
// vs a unary RPC (no `stream`):  packages/contracts/src/rpc.ts:494  WsTerminalWriteRpc
```

Server handlers for streams return an Effect `Stream` (e.g. `subscribeShell`,
`subscribeTerminalEvents`, `subscribeAuthAccess`). A common shape is **snapshot then
live**: emit one snapshot element, then `Stream.concat` the live event stream
(`ws.ts:1086`, `:1731`, `:1777`). The RPC framework multiplexes many concurrent
streams + calls over the one connection and demuxes by request id. Every RPC's `error`
union includes `EnvironmentAuthorizationError` — the scope-denial type (§1.4).

Client side, opening the session is just building a socket layer + the JSON serializer +
the RPC protocol (`packages/client-runtime/src/rpc/session.ts:94`):

```ts
const socketLayer   = Socket.layerWebSocket(connection.socketUrl, { openTimeout: "15 seconds" });
const protocolLayer = Layer.effect(RpcClient.Protocol, RpcClient.makeProtocolSocket({ … }))
  .pipe(Layer.provide(Layer.mergeAll(socketLayer, RpcSerialization.layerJson, …)));
const client = yield* makeWsRpcProtocolClient.pipe(Effect.provide(protocolContext));
// then: client[WS_METHODS.serverGetConfig]({})  — typed call over the ws
```

### 1.2 `wsTicket` — short-lived query token, minted over HTTP, verified on upgrade

The upgrade authenticator checks the `?wsTicket=` query param **first**, then falls back
to normal request auth (cookie/bearer). `apps/server/src/auth/EnvironmentAuth.ts:936`:

```ts
const WEBSOCKET_TICKET_QUERY_PARAM = "wsTicket";               // :501

const authenticateWebSocketUpgrade = Effect.fn(...)(function* (request) {
  const requestUrl = HttpServerRequest.toURL(request);
  if (Option.isSome(requestUrl)) {
    const websocketTicket = requestUrl.value.searchParams.get(WEBSOCKET_TICKET_QUERY_PARAM);
    if (websocketTicket && websocketTicket.trim().length > 0) {
      return yield* sessions.verifyWebSocketToken(websocketTicket).pipe(
        Effect.map((s) => ({ sessionId: s.sessionId, subject: s.subject,
                             method: s.method, scopes: s.scopes, … })),
        mapSessionVerificationErrors,
      );
    }
  }
  return yield* authenticateRequest(request);   // cookie/bearer/dpop fallback
});
```

**Why the ticket exists (verified rationale):** a WebSocket upgrade from a browser
cannot carry a custom `Authorization` header, and putting the long-lived bearer in the
URL is unsafe (logs, history, referrers). So the client uses its already-authenticated
HTTP session to mint a *tiny, short-lived, single-purpose* token and puts **that** in the
query string. Mint + bind into the URL (client side,
`packages/client-runtime/src/authorization/remote.ts:171`):

```ts
const resolveRemoteWebSocketConnectionUrl = Effect.fn(...)(function* (input) {
  const issued = yield* issueRemoteWebSocketTicket({           // POST /api/auth/websocket-ticket
    httpBaseUrl: input.httpBaseUrl, bearerToken: input.bearerToken,
  });                                                          //   Authorization: Bearer <session>
  const url = new URL(input.wsBaseUrl);
  if (url.pathname === "" || url.pathname === "/") url.pathname = "/ws";
  url.searchParams.set("wsTicket", issued.ticket);            // ← ticket in the query
  return url.toString();
});
```

Ticket claims are minimal and short (`SessionStore.ts:419`, `:717`). Note it carries
**only `sid`** — no scopes; scopes are re-read from the persisted session row on verify:

```ts
const WebSocketClaims = Schema.Struct({ v: Schema.Literal(1), kind: Schema.Literal("websocket"),
  sid: AuthSessionId, iat: Schema.Number, exp: Schema.Number });
const DEFAULT_WEBSOCKET_TOKEN_TTL = Duration.minutes(5);      // :404

// issue: HMAC-sign base64url(claims); verify: recompute HMAC + timingSafeEqual, then
// re-load the session row (must exist, not expired, not revoked) → returns its scopes.
```

Server HTTP endpoint that mints it, gated by *being authenticated at all*
(`apps/server/src/auth/http.ts:310`): `.handle("webSocketTicket", … issueWebSocketTicket(session))`.

### 1.3 One-time pairing tokens + RFC-8693 token exchange → scoped session

Pairing tokens are 12 chars from a 32-symbol crowd-safe alphabet (no `0O1I`), rejection-
sampled from CSPRNG bytes, default **5-min TTL**, SQLite-stored, **single-use**
(`apps/server/src/auth/PairingGrantStore.ts`):

```ts
const DEFAULT_ONE_TIME_TOKEN_TTL_MINUTES = Duration.minutes(5);           // :236
const PAIRING_TOKEN_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";        // :246 (no 0/O/1/I)
const PAIRING_TOKEN_LENGTH   = 12;                                        // :247
// generatePairingToken: draw randomBytes, reject bytes >= floor(256/32)*32 to avoid modulo
// bias, map byte % 32 → alphabet char, until 12 chars.                  :257
```

Issue (`issueOneTimeToken`, `:365`): generate id (UUID) + credential, compute
`expiresAt = now + ttl`, **persist** a pairing-link row (`method: "one-time-token"`,
`scopes`, `subject`, `expiresAt`, optional `proofKeyThumbprint`), publish a change event.

Exchange = **consume, once, atomically**, then issue a session. `consume` (`:420`) has a
seeded in-memory grant path (desktop bootstrap) and a persisted path whose one-time-use is
enforced at the DB layer via `consumeAvailable(...)` (an atomic "if unconsumed & unexpired &
unrevoked → mark consumed & return"). Expired/consumed/revoked/thumbprint-mismatch all map
to typed errors.

The exchange that turns a pairing credential into a **scoped session token** is an
RFC-8693-style token exchange (`EnvironmentAuth.ts:690`):

```ts
const exchangeBootstrapCredentialForAccessToken = (credential, requestedScopes, meta, input) =>
  bootstrapCredentials.consume(credential, input).pipe(                    // one-time consume
    Effect.flatMap((grant) => Effect.gen(function* () {
      const grantedScopes = requestedScopes ?? grant.scopes;
      // DOWN-SCOPE ONLY: requested must be ⊆ what the pairing grant allows
      if (!grantedScopes.every((s) => grant.scopes.includes(s)))
        return yield* new ServerAuthScopeNotGrantedError({});
      return yield* sessions.issue({
        method: input?.proofKeyThumbprint ? "dpop-access-token" : "bearer-access-token",
        subject: grant.subject,
        scopes: grantedScopes,
        ...(input?.proofKeyThumbprint ? { proofKeyThumbprint: input.proofKeyThumbprint,
                                          ttl: Duration.hours(1) } : {}),
        client: { ...meta, ...(grant.label ? { label: grant.label } : {}) },
      });
    })),
    // shape the OAuth token-exchange response
    Effect.flatMap((session) => DateTime.now.pipe(Effect.map((now) => ({
      access_token: session.token, issued_token_type: AuthAccessTokenType,
      token_type: input?.proofKeyThumbprint ? "DPoP" : "Bearer",
      expires_in: Math.max(0, Math.floor((session.expiresAt.epochMilliseconds - now.epochMilliseconds)/1000)),
      scope: encodeOAuthScope(session.scopes),
    })))));
```

HTTP surface (`apps/server/src/auth/http.ts:244`, `.handle("token", …)`): standard OAuth
grant `urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token` = the pairing
credential, `subject_token_type = urn:t3:params:oauth:token-type:environment-bootstrap`.
Client caller: `remote.ts:64` `bootstrapRemoteBearerSession` (plain) / `remote.ts:35`
`exchangeRemoteDpopAccessToken` (DPoP). There's also a **browser** variant
(`createBrowserSession`, `EnvironmentAuth.ts:654`) that consumes the same pairing token
but sets an httpOnly session **cookie** instead of returning a bearer.

**Desktop-bootstrap variant (reusable pattern).** At server launch the desktop app hands
the backend a `desktopBootstrapToken`; if present, it's *seeded* as an in-memory grant
with `scopes: AuthAdministrativeScopes`, **24-h TTL**, and `remainingUses: "unbounded"`
(`PairingGrantStore.ts:300`). Rationale, quoted verbatim from the source (`:237`):

```
// The desktop-bootstrap grant rides on a trusted IPC channel (fd3 or stdin) at backend
// launch, so it doesn't have to be short-lived the way a user-facing pairing link does.
// … Unbounded uses so the renderer can re-exchange the seed for a fresh bearer session
// after a page reload … The seed itself stays inside the desktop process and the
// rendered page, both of which the user already implicitly trusts.
```

This is the exact analogue of Continuum's own trusted local process re-bootstrapping —
see §3. (Config field: `apps/server/src/config.ts:73`; wired from CLI bootstrap at
`apps/server/src/cli/config.ts:292,364`.)

### 1.4 Per-RPC capability scopes + the authorize check

Scopes are 8 string literals (`packages/contracts/src/auth.ts:76`):

```
orchestration:read  orchestration:operate  terminal:operate  review:write
access:read  access:write  relay:read  relay:write
```

Two bundles: `AuthStandardClientScopes` = read+operate+terminal+review:write+relay:read;
`AuthAdministrativeScopes` = standard + access:read + access:write + relay:write
(`auth.ts:98`). (`access:*` = the "manage other devices/pairings" self-admin scope;
`review:write` gates diff-review; `relay:*` gates the cloud relay client.)

A **static map** declares the required scope for every WS method
(`apps/server/src/ws.ts:277`, `RPC_REQUIRED_SCOPE`):

```ts
const RPC_REQUIRED_SCOPE = new Map<string, AuthEnvironmentScope>([
  [ORCHESTRATION_WS_METHODS.dispatchCommand, AuthOrchestrationOperateScope],
  [ORCHESTRATION_WS_METHODS.subscribeShell,  AuthOrchestrationReadScope],
  [WS_METHODS.terminalOpen,   AuthTerminalOperateScope],
  [WS_METHODS.terminalWrite,  AuthTerminalOperateScope],
  [WS_METHODS.subscribeTerminalEvents, AuthTerminalOperateScope],
  [WS_METHODS.reviewGetDiffPreview,    AuthReviewWriteScope],
  [WS_METHODS.subscribeAuthAccess,     AuthAccessReadScope],
  // …every method listed…  (read-vs-operate split is the important part)
]);
```

Enforcement wraps *every* handler. The RPC layer is built closed over the authenticated
session, so the check is a pure membership test against `currentSession.scopes`
(`ws.ts:442`):

```ts
const authorizeEffect = (requiredScope, effect) =>
  currentSession.scopes.includes(requiredScope)
    ? effect
    : Effect.fail(authorizationError(requiredScope));        // EnvironmentAuthorizationError

const authorizeStream = (requiredScope, stream) =>
  currentSession.scopes.includes(requiredScope)
    ? stream
    : Stream.fail(authorizationError(requiredScope));

// requiredScopeForMethod THROWS if a method has no entry — you cannot ship an
// unscoped method by accident (:456). Every handler goes through observeRpcEffect /
// observeRpcStream, which call authorize*(requiredScopeForMethod(method), …) (:463).
```

Two properties worth stealing outright: (1) **a method with no scope entry is a hard
error at call time**, not a silent allow; (2) read and operate are *different scopes*, so
"observe-only" is expressible as a scope subset with zero special-casing — an observer
session simply lacks `*:operate`.

### 1.5 DPoP — token↔key binding + replay protection

Optional, layered on top of a bearer token. The token carries a `jkt` (JWK thumbprint)
claim; the client proves possession of the matching P-256 private key by signing a
per-request DPoP JWT. Verification (`packages/shared/src/dpop.ts:112`, pure):

```ts
verifyDpopProof({ proof, method, url, nowEpochSeconds, expectedThumbprint, expectedAccessToken })
// checks, in order:
//  - compact JWT, header typ=dpop+jwt alg=ES256, embeds a P-256 public JWK
//  - thumbprint(JWK) === expectedThumbprint            (token↔key binding)
//  - payload.htm === request method, payload.htu === normalized request URL
//  - payload.ath === base64url(sha256(accessToken))    (proof↔token binding)
//  - iat within ±5s future / maxAge 300s past          (freshness)
//  - ES256 signature verifies against the embedded JWK
// → { ok, thumbprint, jti, iat }
```

**Replay protection** is a first-seen store keyed by the proof (`apps/server/src/auth/dpop.ts:56`):

```ts
const replayKey = base64url(sha256(`${thumbprint}:${jti}`));
yield* secretStore.create(`dpop-proof-${replayKey}`, /*…metadata…*/);   // atomic exclusive create
//   create() uses open(flag:"wx") → EEXIST if seen before → mapped to
//   ServerAuthInvalidCredentialError("DPoP proof replayed.")  (dpop.ts:17)
```

Binding is checked on both HTTP requests (`EnvironmentAuth.ts:602`: a `jkt`-bearing token
*requires* a valid DPoP proof, and a `DPoP `-scheme authorization *requires* a proof-bound
token) and on the WS-ticket-issuing HTTP call. DPoP is *not* re-verified per WS frame — it
secures the HTTP calls (token exchange, ticket issue); the ws itself trusts the ticket.

### 1.6 Session tokens + secret storage

Session tokens are stateless-signed + DB-backed. Claims (`SessionStore.ts:406`) carry
`sid, sub, scopes, method, jkt?, iat, exp`; the token is
`base64url(json(claims)) + "." + HMAC-SHA256(payload, signingKey)`. Verify recomputes the
HMAC (`timingSafeEqual`, `utils.ts:38`), decodes, checks `exp`, then loads the session row
(must exist + not revoked). Default TTL **30 days** (bearer/cookie); **1 hour** if DPoP-bound.
Revocation is a DB flag → verify fails; there's `revoke` and `revokeAllExcept`. Signing key
is 32 random bytes via `getOrCreateRandom` in the secret store.

Secret store (`apps/server/src/auth/ServerSecretStore.ts`) = plaintext files under a
`0700` dir, each secret a `0600` file, two write modes:

```ts
// set(): atomic replace — write temp, chmod 0600, rename over target, chmod again (:187)
// create(): exclusive create — open(flag:"wx", mode:0o600) → fails if exists (:224)
//           (this EEXIST-as-signal is exactly what powers DPoP replay detection)
```

---

## 2. Code snippets — the Swift / Continuum sketch

The point: express the *same* model natively. Continuum reaches its box over agent #1's
channel (SSH/tailscale/tunnel), so the "how a header gets attached" detail differs, but
the **pairing token → scoped session → per-message authorization** spine is identical.

These are illustrative signatures, not a finished module — enough for the implementing
agent to build against.

### 2.1 Scopes as an OptionSet (observe-only = absence of control)

```swift
// ContinuumRuntime/Auth/Scope.swift  (new)
public struct Scope: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    // Mirror t3code's read/operate split so "observe-only" is a subset, not a flag.
    public static let orchestrationRead    = Scope(rawValue: 1 << 0) // see the activity tree / snapshots
    public static let orchestrationOperate = Scope(rawValue: 1 << 1) // dispatch commands, move tiles
    public static let terminalOperate      = Scope(rawValue: 1 << 2) // write keystrokes to a pane
    public static let accessRead           = Scope(rawValue: 1 << 3) // list paired devices
    public static let accessWrite          = Scope(rawValue: 1 << 4) // pair/revoke devices

    /// The iOS phone as a read-only observer (docs/38 §E "observer-only first").
    public static let observer: Scope = [.orchestrationRead]
    /// A second full Mac.
    public static let operator: Scope = [.orchestrationRead, .orchestrationOperate, .terminalOperate]
    public static let admin: Scope = [.operator, .accessRead, .accessWrite]
}
```

### 2.2 A one-time `PairingToken` (TTL, single-use)

```swift
// ContinuumRuntime/Auth/PairingToken.swift  (new)
public struct PairingToken: Codable, Sendable {
    public let id: UUID
    public let credential: String          // 12 chars, crowd-safe alphabet, CSPRNG
    public let scopes: Scope               // the CEILING the exchange may grant
    public let expiresAt: Date
    public var consumedAt: Date?           // nil until first successful exchange
    public var revokedAt: Date?
}

enum PairingAlphabet {
    static let symbols = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")   // no 0/O/1/I
    static func credential(length: Int = 12) -> String {
        var out = ""; let n = symbols.count
        let limit = (256 / n) * n                                    // reject modulo bias
        while out.count < length {
            var b: UInt8 = 0; _ = SecRandomCopyBytes(kSecRandomDefault, 1, &b)
            if Int(b) >= limit { continue }
            out.append(symbols[Int(b) % n])
        }
        return out
    }
}

actor PairingStore {                        // SQLite/GRDB-backed in practice
    func issue(scopes: Scope, ttl: TimeInterval = 300, label: String? = nil) -> PairingToken { … }

    /// Atomic single-use consume. Mirrors t3code `consumeAvailable`:
    /// one UPDATE ... WHERE consumedAt IS NULL AND revokedAt IS NULL AND expiresAt > now.
    func consume(_ credential: String) throws -> PairingToken {
        // throws .unknown / .expired / .alreadyUsed / .revoked
    }
}
```

### 2.3 The exchange → a scoped `Session` (down-scope only)

```swift
// ContinuumRuntime/Auth/SessionStore.swift  (new)
public struct Session: Codable, Sendable {
    public let id: UUID
    public let scopes: Scope
    public let subject: String
    public let expiresAt: Date
    public var revokedAt: Date?
    // token = base64url(json(claims)) + "." + HMAC-SHA256(payload, signingKey)
}

func exchange(pairingCredential: String, requested: Scope?) throws -> (token: String, scopes: Scope) {
    let grant = try pairingStore.consume(pairingCredential)          // one-time
    let granted = requested ?? grant.scopes
    guard grant.scopes.isSuperset(of: granted) else { throw AuthError.scopeNotGranted }  // ⊆ only
    let session = sessionStore.issue(scopes: granted, subject: grant.subject, ttl: .days(30))
    return (session.token, session.scopes)
}
```

### 2.4 Per-message authorization (mirror `RPC_REQUIRED_SCOPE`)

Continuum's live payload is a **projection/op stream**, not a big RPC surface (§4). But
the *control* messages a device may send still want the same table:

```swift
// ContinuumRuntime/Auth/MessageScope.swift  (new)
enum ControlMessage: String { case moveTile, resizeTile, spawnTerminal, sendKeys, subscribeActivity, listDevices, pairDevice }

let requiredScope: [ControlMessage: Scope] = [
    .subscribeActivity: .orchestrationRead,      // observers may subscribe
    .moveTile:          .orchestrationOperate,
    .resizeTile:        .orchestrationOperate,
    .spawnTerminal:     .orchestrationOperate,
    .sendKeys:          .terminalOperate,
    .listDevices:       .accessRead,
    .pairDevice:        .accessWrite,
]

func authorize(_ msg: ControlMessage, session: Session) throws {
    guard let need = requiredScope[msg] else { throw AuthError.unscopedMessage(msg) } // hard fail
    guard session.scopes.contains(need) else { throw AuthError.missingScope(need) }
}
```

### 2.5 "Pair my iPhone as a read-only observer" — end-to-end flow

Over whatever channel Continuum uses (the Mac's local server reached via agent #1's
tunnel/tailscale; loopback in the same-network case):

```
Mac (host, has the canvas + sessions)                 iPhone (new device)
─────────────────────────────────────                ────────────────────
1. User: "Pair a device (observe-only)"
   token = pairingStore.issue(scopes: .observer, ttl: 300s)
   render token.credential as a QR / 12-char code ───────────►  scan / type
                                                     2. POST /pair  { credential, requested: observer,
                                                                      device: {name, os:iOS} }
3. session = exchange(credential, requested:.observer)
   (consume once; .observer ⊆ .observer ✓; issue 30d token)
   ◄──────────────────────────────  { token, scopes:[orchestrationRead], expiresAt }
                                                     4. store token in iOS Keychain
                                                     5. wsTicket = POST /ws-ticket (Authorization: Bearer token)
6. verify wsTicket on upgrade ◄───── open  wss://…/ws?wsTicket=…
7. session.scopes = [orchestrationRead]
   → phone MAY subscribeActivity (the SidebarTree projection, docs/38 §C)
   → phone MAY NOT sendKeys / moveTile / spawnTerminal  (no *:operate) → rejected per-message
```

The QR/code path is exactly t3code's `/pair#token=…` URL (`EnvironmentAuth.ts:906`
`issueStartupPairingUrl` puts the token in the URL **fragment**, not the query, so it
never hits the server logs). For iOS, a QR code or an AirDrop of that fragment-URL is the
natural transport.

---

## 3. What Continuum steals — mapped to Decision D / E + seams

`docs/38` already commits to: **auth on every path incl. loopback** (implied by
"observed from iOS" + a remote host), **observer-only iOS first** (§E open item), and a
**store-protocol / sync seam** (§E). t3code gives us a battle-tested shape for the auth
half of that. Concretely:

1. **A new Continuum auth/pairing module** — `ContinuumRuntime/Auth/` with
   `Scope` (OptionSet), `PairingStore` (one-time tokens, SQLite, atomic consume),
   `SessionStore` (HMAC-signed scoped tokens, revocable), and a per-message
   `requiredScope` table. This is *net-new* (docs/38 §Current-state: "Zero networking /
   sync code anywhere"). Steal the **read/operate scope split** and the **hard-fail on
   unscoped message** — both are cheap and both directly serve the observer-only goal.

2. **The iOS observer handshake** = §2.5. Maps to Decision E's "iOS = spatial sync +
   activity tree + on-demand pane view" and its open "observer-only vs control". The
   observer scope makes "spatial sync + activity tree, but no control" a *type-level*
   guarantee: an `.observer` token literally cannot carry `orchestrationOperate` or
   `terminalOperate`, so the phone physically cannot move a tile or type into a pane even
   if the client is compromised/buggy. This is the auth complement to Decision E's I5
   ("synced payload contains no runtime handles"): E keeps *secrets* off the wire; scopes
   keep *capabilities* off the untrusted device.

3. **Auth on EVERY path, including loopback (hard line).** t3code authenticates the WS
   upgrade *unconditionally* — there is no `if (isLocalhost) skipAuth`. The desktop case
   is handled not by bypassing auth but by **seeding a trusted bootstrap grant** the local
   process already holds (§1.3). **Steal this exactly:** Continuum's own Mac process gets
   an in-memory admin bootstrap grant at launch (the analogue of `desktopBootstrapToken`),
   and *every* connection — including a second local client and the SSH-tunneled remote —
   still presents a real scoped session. This kills the "it's just localhost, it's fine"
   class of bug before it exists, and it's the only way the remote (Decision D, `ssh://`)
   and iOS (Decision E) stories share one code path.

4. **The `wsTicket` pattern for any non-header-capable transport.** Whether Continuum's
   live channel is a WebSocket or something else, the *"mint a short-lived, single-purpose,
   scope-less-but-session-bound token over the authenticated control path, hand it to the
   dumb pipe"* pattern applies wherever the pipe can't carry a real credential. It's a
   5-minute HMAC token; trivial to reimplement (§1.2).

5. **DPoP is available but likely deferred.** The token↔key binding + replay store
   (§1.5) is the right tool *if* a Continuum bearer could be exfiltrated from a device and
   replayed by an attacker on the same network. For phase-1 (observer iOS over a private
   tailnet, tokens in Keychain) this is probably over-engineering — note it as the upgrade
   path for "untrusted network" / "web client", not day-one work. The *replay-store trick*
   (`open(wx)` → EEXIST = replay) is worth remembering independently.

**Where these land relative to the other steal-docs:** this module is consumed by whatever
carries the live projection stream (the sync/transport doc) and sits behind agent #1's
reachability. It does not itself open sockets to the box.

---

## 4. What does NOT transfer

Continuum is **offline-first with a deterministic op-log** (docs/38 §E, resolved
2026-06-30), not a thin client fully dependent on a live server. That changes what the
transport *is*, and therefore which parts of t3code's model apply.

- **The full 60-method WS-RPC server does NOT transfer.** t3code's clients are
  *thin* — every file read, git op, terminal write is an RPC round-trip to the server
  because the client owns no state. Continuum clients own the canvas locally and **sync via
  an op-log + a projection (activity-tree) stream** (docs/38 §C/§E). So Continuum does not
  need `projectsReadFile`, `vcsCreateWorktree`, `previewOpen`, etc. as authed RPCs; those
  are local or op-log operations. The transport is much narrower: **push/pull ops** + a
  **derived projection stream** + a small set of **remote-only control messages** (e.g.
  "spawn a terminal on the VPS", "send keys to a remote pane").

- **`RpcServer.toHttpEffectWebsocket` / Effect-RPC specifically does NOT transfer** —
  it's a TS/Effect construct. What transfers is the *idea* (one authed connection,
  typed messages, streams multiplexed on it, every message scope-checked). A native
  Continuum implementation would be a Swift `URLSessionWebSocketTask` (or the sync
  transport of choice — CloudKit is on the table in docs/38 §E) carrying `Codable`
  op/projection messages.

- **Where the auth model still applies vs. not:**
  - **Applies fully:** the moment there is *any* remote or cross-device connection — the
    SSH-reached VPS host (Decision D), the iOS observer (Decision E), a second Mac. Pairing
    → scoped session → per-message authorize is exactly right there.
  - **Applies partially:** if sync is **CloudKit** (docs/38 §E "CloudKit-first"), then
    *device identity + record-level access* is Apple's (iCloud account, CKShare
    permissions), and Continuum's own `SessionStore`/`wsTicket` may be **unnecessary for
    the sync path** — you'd lean on CloudKit's auth and only need Continuum scopes for the
    **non-CloudKit control channel** (typing into a remote pane, spawning remote sessions),
    which CloudKit can't carry. So the scope table survives; the token machinery may not,
    on the sync leg.
  - **Does NOT apply:** the **local, single-device, offline** case. There is no connection
    to authenticate, so there is no session to check — the op-log is just written to disk.
    (The bootstrap-grant-on-launch from §3.3 exists so that the *instant* a second client
    appears, the path is already authed — but with zero peers, it's inert.)

- **`access:*` self-admin scopes + the live `subscribeAuthAccess` device-list stream**
  are a nice-to-have (a "manage my paired devices" screen) but not core; defer until there's
  more than one device to manage.

---

## 5. Open questions / forks (for Dylan / the implementing agent)

1. **Does Continuum even need a control channel in phase 1, or observer-only first?**
   docs/38 §E leans observer-only. If observer-only ships first, the *entire* `*:operate`
   half of the scope model is present-but-unused — which is fine and cheap (it's an
   OptionSet), and it means "add control later" is purely additive. **Recommendation:
   build the scope enum in full now, grant only `.observer` to iOS, wire only the
   read/subscribe messages.** (Matches how t3code lets you issue a down-scoped pairing token
   today without touching the server.)

2. **Sync transport = CloudKit vs. a Continuum relay (docs/38 §E open).** This decides
   whether Continuum's own `SessionStore`/`wsTicket` are load-bearing (relay/WS path) or
   mostly redundant on the sync leg (CloudKit path). The **scope model is transport-agnostic
   and survives either way**; the token/ticket machinery is only needed on a self-hosted
   channel. Don't build `wsTicket` until the transport is chosen.

3. **Where does the control channel *terminate* for a remote (SSH) host?** If the VPS runs
   a small "Continuum host daemon" (docs/38 §D open: "ssh-wrap vs. daemon"), that daemon is
   the natural home for `PairingStore`/`SessionStore` on the VPS — and now there are *two*
   auth authorities (the Mac's, the VPS's). Fork: **one identity that both trust** (harder,
   cleaner) vs. **pair the Mac↔VPS as its own device relationship** (reuses this whole
   module verbatim; the Mac is just another "client" of the VPS daemon). The latter is the
   t3code-native answer and I'd lean there.

4. **Identity/account model (docs/38 §E open).** t3code's `subject` is an opaque string
   ("browser", "cli-issued-session", "desktop-bootstrap") — there is **no user-account
   notion** in the auth core; a subject is just a label on a grant. Continuum can start the
   same way (device-scoped, no accounts) and only introduce accounts when multi-user
   sharing is real. Do not build accounts to get iOS observing your own machine.

5. **DPoP now or never-until-web?** (§3.5) Fork on threat model: private tailnet + Keychain
   tokens → skip. A future web/PWA client or a shared/hostile network → adopt. Keep the
   `jkt`-in-claims field reserved so it's not a migration later.

6. **Token TTLs.** t3code: pairing 5 min, wsTicket 5 min, bearer 30 d, DPoP-bound 1 h,
   desktop-bootstrap 24 h. These are sane defaults to copy; the only Continuum-specific
   call is whether an **iOS observer** token should be long (30 d, convenient) or short
   (re-pair often, safer for a phone). Suggest 30 d + easy one-tap revoke from the Mac
   (which needs the `access:*` path, item 4 above → so maybe revoke-by-re-pair in phase 1).

---

### Appendix — file index (verified reads)

| Concern | File:line |
|---|---|
| WS route + upgrade auth + RPC→ws | `apps/server/src/ws.ts:1793`, `:1811`, `:1842` |
| Scope map + authorize check | `apps/server/src/ws.ts:277`, `:442`, `:456`, `:463` |
| wsTicket verify-on-upgrade | `apps/server/src/auth/EnvironmentAuth.ts:936`, param `:501` |
| wsTicket mint (HTTP) | `apps/server/src/auth/http.ts:310`; issue impl `EnvironmentAuth.ts:918` |
| wsTicket claims + TTL | `apps/server/src/auth/SessionStore.ts:419`, `:404`, `:717`, `:752` |
| Client: ticket→ws URL | `packages/client-runtime/src/authorization/remote.ts:131`, `:171` |
| Client: open ws session | `packages/client-runtime/src/rpc/session.ts:94` |
| Pairing token gen (12ch/CSPRNG/reject-bias) | `apps/server/src/auth/PairingGrantStore.ts:246`, `:257` |
| Pairing issue / one-time consume | `PairingGrantStore.ts:365`, `:420` |
| Desktop-bootstrap seeded grant (24h/unbounded) | `PairingGrantStore.ts:300`, rationale `:237` |
| Token exchange (RFC-8693) → scoped session | `EnvironmentAuth.ts:690`; HTTP `http.ts:244`; client `remote.ts:64` |
| Browser cookie-session variant | `EnvironmentAuth.ts:654`; HTTP `http.ts:211` |
| DPoP proof verify (pure) | `packages/shared/src/dpop.ts:112` |
| DPoP replay store (wx-EEXIST) | `apps/server/src/auth/dpop.ts:56`, map `:17` |
| Session token issue/verify (HMAC + DB) | `SessionStore.ts:571`, `:654` |
| HMAC sign / timing-safe compare | `apps/server/src/auth/utils.ts:34`, `:38` |
| Secret store (0700 dir / 0600 / atomic / wx) | `apps/server/src/auth/ServerSecretStore.ts:158`, `:187`, `:224` |
| Scope literals + bundles | `packages/contracts/src/auth.ts:76`, `:98`, `:105` |
| RPC group + `stream:true` | `packages/contracts/src/rpc.ts:684`, `:487` |
| CLI `auth pairing/session …` | `apps/server/src/cli/auth.ts:84`, `:162` |
