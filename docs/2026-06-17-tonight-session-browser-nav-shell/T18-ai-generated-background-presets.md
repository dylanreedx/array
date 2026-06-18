# T18 — AI-generated background preset spike

Status: draft / optional spike
Tag: tonight [visual] [ai]
Depends on: T17

## Goal
Explore generating 5–10 cohesive background/theme presets using OpenAI image generation, while keeping API keys secure and outputs cached.

## Security note
A key was pasted during planning and must be treated as compromised. Do not use it. Revoke/rotate before any implementation. The app must never store API keys in workspace files, plaintext settings, renderer state, logs, or crash reports.

## Research-backed direction
- Use OpenAI Image API for one-shot generation.
- Optionally use Responses API for iterative/cohesive workflows.
- Store API key in OS-backed credential storage only.
- Generate from a shared style template plus per-preset variants.
- Cache by hash of model + prompt template version + preset spec + size + quality.

## Prompt template draft
```text
Create a desktop app background/theme preset.
Shared style: calm premium productivity app, translucent UI friendly, subtle depth.
Preset variant: [name, mood, palette, composition, density].
Constraints: no text, no logos, no watermark, no people, avoid high-contrast clutter.
```

## Scope
- Decision/prototype service only unless low-risk.
- User settings: model, quality, resolution, number of presets, style seed, cache clear.
- Generate 5–10 variants such as Aurora Slate, Warm Paper, Midnight Glass, Forest Mist, Solar Sand, Violet Studio.
- Track usage + cost

## Acceptance criteria
- [ ] API key storage plan uses OS keychain/secure storage.
- [ ] Generated images are cached with metadata sidecars.
- [ ] User can regenerate/delete generated presets.
- [ ] No key or private prompt data appears in logs.
- [ ] Output presets feed into T17 background model.

## Verification
- Dry-run with mocked API client before real API call.
- Inspect logs/settings/workspace files for absence of secrets.

## TDD sketch
Mock API first; never hit OpenAI in checks.

```swift
let client = FakeImageGenerationClient(resultImageData: Data([1,2,3]))
let cache = InMemoryBackgroundPresetCache()
let service = AIPresetGenerationService(client: client, cache: cache, keyStore: FakeSecureKeyStore())

let presets = try await service.generate(styleSeed: "calm cyber forest", count: 6, quality: .low)
expect(presets.count == 6, "generates requested preset count")
expect(client.requests.allSatisfy { !$0.prompt.contains("sk-") }, "prompts never include API keys")
expect(cache.entries.count == 6, "generated presets are cached")
```

Secret storage/logging:

```swift
try keyStore.saveAPIKey("sk-test-secret")
expect(!WorkspaceDocument.debugDump().contains("sk-test-secret"), "workspace never stores API key")
expect(!TestLogSink.contents.contains("sk-test-secret"), "logs never contain API key")
```
