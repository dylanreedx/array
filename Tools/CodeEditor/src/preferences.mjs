export const defaultPreferences = Object.freeze({appearance: "system", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: 13, lineHeight: 1.5, lineNumbers: true, wordWrap: false, vimEnabled: false})
export function normalizePreferences(value = {}, previous = defaultPreferences) {
  const next = {...previous, ...value}
  next.appearance = ["system", "light", "dark"].includes(next.appearance) ? next.appearance : "system"
  next.fontFamily = typeof next.fontFamily === "string" && next.fontFamily.trim() ? next.fontFamily : defaultPreferences.fontFamily
  next.fontSize = Number.isFinite(next.fontSize) ? Math.min(32, Math.max(9, next.fontSize)) : 13
  next.lineHeight = Number.isFinite(next.lineHeight) ? Math.min(2.2, Math.max(1.1, next.lineHeight)) : 1.5
  for (const key of ["lineNumbers", "wordWrap", "vimEnabled"]) next[key] = typeof next[key] === "boolean" ? next[key] : defaultPreferences[key]
  return next
}
