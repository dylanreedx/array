// The built-in agent character packs, as resources alone. They are a target of
// their own so the iOS app, which links Core, does not carry them: the Mac app
// and CoreChecks depend on this target, and `AgentCharacterBundled` finds its
// bundle beside Core's.
