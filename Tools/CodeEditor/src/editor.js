import {autocompletion, closeBrackets, closeBracketsKeymap} from "@codemirror/autocomplete"
import {defaultKeymap, history, historyKeymap, indentWithTab, undo, redo} from "@codemirror/commands"
import {bracketMatching, HighlightStyle, foldGutter, foldKeymap, indentOnInput, syntaxHighlighting, StreamLanguage} from "@codemirror/language"
import {cpp} from "@codemirror/lang-cpp"
import {css} from "@codemirror/lang-css"
import {go} from "@codemirror/lang-go"
import {html} from "@codemirror/lang-html"
import {javascript} from "@codemirror/lang-javascript"
import {json} from "@codemirror/lang-json"
import {markdown} from "@codemirror/lang-markdown"
import {python} from "@codemirror/lang-python"
import {rust} from "@codemirror/lang-rust"
import {setDiagnostics} from "@codemirror/lint"
import {csharp} from "@codemirror/legacy-modes/mode/clike"
import {shell} from "@codemirror/legacy-modes/mode/shell"
import {swift} from "@codemirror/legacy-modes/mode/swift"
import {highlightSelectionMatches, searchKeymap, openSearchPanel} from "@codemirror/search"
import {Annotation, Compartment, EditorState, Transaction} from "@codemirror/state"
import {crosshairCursor, drawSelection, dropCursor, EditorView, highlightActiveLine, highlightActiveLineGutter, highlightSpecialChars, hoverTooltip, keymap, lineNumbers, rectangularSelection} from "@codemirror/view"
import {tags} from "@lezer/highlight"
import {vim, getCM, Vim} from "@replit/codemirror-vim"
import {defaultPreferences, normalizePreferences} from "./preferences.mjs"
import {applyMarkdownCommand} from "./markdown-commands.mjs"
import {RevisionProtocol} from "./revision-protocol.mjs"

const hostEdit = Annotation.define()
const language = new Compartment()
const appearance = new Compartment()
const editable = new Compartment()
const numbers = new Compartment()
const wrapping = new Compartment()
const vimKeymap = new Compartment()
let preferences = {...defaultPreferences}
let hookedVim = null
const systemDark = window.matchMedia("(prefers-color-scheme: dark)")
function themeExtension() {
  const dark = preferences.appearance === "dark" || (preferences.appearance === "system" && systemDark.matches)
  document.documentElement.dataset.appearance = dark ? "dark" : "light"
  return [EditorView.theme({
    "&": {fontSize: `${preferences.fontSize}px`, backgroundColor: "var(--editor-background)", color: "var(--editor-text)"},
    ".cm-gutters": {backgroundColor: "var(--editor-background)", color: "var(--editor-muted)", borderRight: "none"},
    ".cm-activeLine, .cm-activeLineGutter": {backgroundColor: "var(--editor-active)"},
    ".cm-cursor": {borderLeftColor: "var(--editor-accent)"},
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": {backgroundColor: "var(--editor-selection)"},
    ".cm-scroller": {fontFamily: preferences.fontFamily, lineHeight: String(preferences.lineHeight)}
  }, {dark}), syntaxHighlighting(HighlightStyle.define([
    {tag: [tags.keyword, tags.modifier, tags.operatorKeyword], color: dark ? "#C4A7E7" : "#7C3EB1"},
    {tag: [tags.string, tags.special(tags.string)], color: dark ? "#A8D5BA" : "#237A50"},
    {tag: [tags.number, tags.bool, tags.null], color: dark ? "#EABF8E" : "#A25B13"},
    {tag: [tags.comment], color: dark ? "#8996AA" : "#69788C", fontStyle: "italic"},
    {tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], color: dark ? "#9DBBF5" : "#315BA6"},
    {tag: [tags.typeName, tags.className, tags.tagName], color: dark ? "#8ED0D2" : "#087D86"},
    {tag: [tags.heading], color: dark ? "#9DBBF5" : "#315BA6", fontWeight: "bold"},
    {tag: tags.link, textDecoration: "underline"},
    {tag: tags.emphasis, fontStyle: "italic"}, {tag: tags.strong, fontWeight: "bold"},
    {tag: tags.invalid, color: dark ? "#FF9494" : "#C33E48"}
  ]))]
}
function hookVimMode() {
  const cm = view && getCM(view)
  if (cm && cm !== hookedVim) {
    cm.on("vim-mode-change", event => post("vimModeChanged", {documentId: protocol.documentId, mode: event.mode}))
    hookedVim = cm
  }
  if (!cm) hookedVim = null
  post("vimModeChanged", {documentId: protocol.documentId, mode: cm ? (cm.state.vim?.insertMode ? "insert" : cm.state.vim?.visualMode ? "visual" : "normal") : "off"})
}
function setPreferences(value) {
  const previousVim = preferences.vimEnabled
  preferences = normalizePreferences(value, preferences)
  const themes = themeExtension()
  if (view) {
    const effects = [appearance.reconfigure(themes), numbers.reconfigure(preferences.lineNumbers ? lineNumbers() : []), wrapping.reconfigure(preferences.wordWrap ? EditorView.lineWrapping : [])]
    if (previousVim !== preferences.vimEnabled) effects.push(vimKeymap.reconfigure(preferences.vimEnabled ? vim({status: false}) : []))
    view.dispatch({effects})
    hookVimMode()
  }
  return preferences
}
systemDark.addEventListener("change", () => { if (preferences.appearance === "system") setPreferences({}) })
Vim.defineEx("write", "w", () => post("saveRequest", {documentId: protocol.documentId, revision: protocol.revision}))
const protocol = new RevisionProtocol()
let view = null
let nextRequestID = 1
const completionRequests = new Map()
const hoverRequests = new Map()

function post(type, body = {}) {
  const handler = window.webkit?.messageHandlers?.codeEditor
  if (handler) handler.postMessage({type, ...body})
}

function languageExtension(name) {
  switch ((name || "").toLowerCase()) {
    case "javascript": case "jsx": return javascript({jsx: true})
    case "typescript": case "tsx": return javascript({jsx: true, typescript: true})
    case "python": return python()
    case "go": return go()
    case "rust": return rust()
    case "html": return html()
    case "css": return css()
    case "json": return json()
    case "markdown": return markdown()
    case "c": case "cpp": case "c++": return cpp()
    case "csharp": case "c#": return StreamLanguage.define(csharp)
    case "swift": return StreamLanguage.define(swift)
    case "shell": case "bash": case "sh": case "zsh": return StreamLanguage.define(shell)
    default: return []
  }
}

function extensions(languageName) {
  return [
    editable.of([EditorView.editable.of(true), EditorState.readOnly.of(false)]),
    vimKeymap.of(preferences.vimEnabled ? vim({status: false}) : []),
    appearance.of(themeExtension()), numbers.of(preferences.lineNumbers ? lineNumbers() : []), wrapping.of(preferences.wordWrap ? EditorView.lineWrapping : []),
    foldGutter(), highlightSpecialChars(), history(), drawSelection(), dropCursor(),
    EditorState.allowMultipleSelections.of(true), indentOnInput(),
    bracketMatching(), closeBrackets(), autocompletion({override: [completionSource]}), nativeHover,
    rectangularSelection(), crosshairCursor(), highlightActiveLine(),
    highlightActiveLineGutter(), highlightSelectionMatches(),
    keymap.of([{key: "Mod-s", run: () => { post("saveRequest", {documentId: protocol.documentId, revision: protocol.revision}); return true }}, ...closeBracketsKeymap, indentWithTab, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap]),
    language.of(languageExtension(languageName)),
    EditorView.domEventHandlers({
      mousedown(event, view) {
        if (!event.metaKey || event.button !== 0) return false
        const position = view.posAtCoords({x: event.clientX, y: event.clientY})
        return position == null ? false : requestDefinition(position)
      },
      keydown(event, view) {
        if (event.key !== "F12") return false
        return requestDefinition(view.state.selection.main.head)
      }
    }),
    EditorView.updateListener.of(update => {
      if (update.focusChanged) post("focusChanged", {documentId: protocol.documentId, focused: update.view.hasFocus})
      if (update.selectionSet) postViewState()
      if (!update.docChanged || update.transactions.some(transaction => transaction.annotation(hostEdit))) return
      const changes = []
      update.changes.iterChanges((from, to, _fromB, _toB, inserted) => changes.push({from, to, insert: inserted.toString()}))
      post("changed", protocol.userChange(changes))
    })
  ]
}

function postViewState() {
  if (!view) return
  const head = view.state.selection.main.head
  const line = view.state.doc.lineAt(head)
  post("viewState", {
    documentId: protocol.documentId,
    line: line.number,
    column: head - line.from + 1,
    scrollTop: view.scrollDOM.scrollTop,
    scrollLeft: view.scrollDOM.scrollLeft
  })
}

function requireDocument(documentId) {
  if (!view || protocol.documentId !== documentId) throw new Error("document is not loaded")
}

function requestPosition(type, position, requestID = nextRequestID++) {
  const line = view.state.doc.lineAt(position)
  post(type, {
    documentId: protocol.documentId,
    revision: protocol.revision,
    offset: position,
    line: line.number - 1,
    column: position - line.from,
    requestId: requestID
  })
  return requestID
}

function completionSource(context) {
  return new Promise(resolve => {
    const requestID = nextRequestID++
    const position = context.matchBefore(/\w*/)?.from ?? context.pos
    completionRequests.set(requestID, {resolve, position})
    context.addEventListener("abort", () => {
      completionRequests.delete(requestID)
      resolve(null)
    }, {onDocChange: true})
    requestPosition("completionRequest", context.pos, requestID)
  })
}

const nativeHover = hoverTooltip((_view, position) => new Promise(resolve => {
  hoverRequests.forEach(request => request.resolve(null))
  hoverRequests.clear()
  const requestID = nextRequestID++
  hoverRequests.set(requestID, {resolve, position})
  requestPosition("hoverRequest", position, requestID)
}))

function requestDefinition(position) {
  requestPosition("definitionRequest", position)
  return true
}

window.arrayEditor = {
  loadDocument({documentId, text, language: languageName, revision}) {
    completionRequests.forEach(request => request.resolve(null))
    completionRequests.clear()
    hoverRequests.forEach(request => request.resolve(null))
    hoverRequests.clear()
    protocol.load(documentId, revision)
    const state = EditorState.create({doc: text, extensions: extensions(languageName)})
    if (view) {
      view.setState(state)
      view.scrollDOM.scrollTop = 0
      view.scrollDOM.scrollLeft = 0
    } else {
      view = new EditorView({state, parent: document.querySelector("#editor")})
      view.scrollDOM.addEventListener("scroll", postViewState, {passive: true})
    }
    hookVimMode()
    return {documentId, revision}
  },

  applyEdits({documentId, expectedRevision, revision, changes}) {
    requireDocument(documentId)
    const transaction = view.state.update({changes, annotations: [hostEdit.of(true), Transaction.addToHistory.of(false)]})
    const result = protocol.acceptHostEdit(documentId, expectedRevision, revision)
    if (!result.accepted) return result
    view.dispatch(transaction)
    return result
  },

  provideCompletions({documentId, requestId, items, isIncomplete}) {
    requireDocument(documentId)
    const request = completionRequests.get(requestId)
    if (!request) return {accepted: false, reason: "requestExpired"}
    completionRequests.delete(requestId)
    request.resolve({
      from: request.position,
      options: items.map(item => ({
        label: item.label,
        detail: item.detail || undefined,
        type: item.kind || undefined,
        apply: item.insertText || item.label
      })),
      filter: false,
      validFor: isIncomplete ? undefined : /^\\w*$/
    })
    return {accepted: true}
  },

  setDiagnostics({documentId, revision, diagnostics}) {
    requireDocument(documentId)
    if (revision !== protocol.revision) return {accepted: false, reason: "revisionMismatch", revision: protocol.revision}
    view.dispatch(setDiagnostics(view.state, diagnostics.map(diagnostic => ({
      from: diagnostic.from,
      to: diagnostic.to,
      severity: diagnostic.severity,
      message: diagnostic.message
    }))))
    return {accepted: true, revision: protocol.revision}
  },

  provideHover({documentId, requestId, text}) {
    requireDocument(documentId)
    const request = hoverRequests.get(requestId)
    if (!request) return {accepted: false, reason: "requestExpired"}
    hoverRequests.delete(requestId)
    if (!text) request.resolve(null)
    else request.resolve({
      pos: request.position,
      create() {
        const dom = document.createElement("div")
        dom.className = "cm-native-hover"
        dom.textContent = text
        return {dom}
      }
    })
    return {accepted: true}
  },

  setLanguage({documentId, name}) {
    requireDocument(documentId)
    view.dispatch({effects: language.reconfigure(languageExtension(name)), annotations: hostEdit.of(true)})
    return {documentId, revision: protocol.revision}
  },

  setPreferences,

  setAppearance({appearance}) { return setPreferences({appearance}) },

  runCommand({documentId, command, line, column, scrollTop, scrollLeft}) {
    requireDocument(documentId)
    if (/^markdown[1-8]$/.test(command)) return {handled: applyMarkdownCommand(view, command)}
    if (command === "resumeEditing") { view.dispatch({effects: editable.reconfigure([EditorView.editable.of(true), EditorState.readOnly.of(false)])}); return {handled: true} }
    if (command === "undo") return {handled: undo(view)}
    if (command === "redo") return {handled: redo(view)}
    if (command === "find") return {handled: openSearchPanel(view)}
    if (command === "focus") { view.focus(); return {handled: true} }
    if (command === "selectAll") {
      view.dispatch({selection: {anchor: 0, head: view.state.doc.length}})
      return {handled: true}
    }
    if (command === "reveal") {
      const targetLine = view.state.doc.line(Math.max(1, Math.min(line || 1, view.state.doc.lines)))
      const position = Math.min(targetLine.to, targetLine.from + Math.max(0, (column || 1) - 1))
      view.dispatch({
        selection: {anchor: position},
        effects: EditorView.scrollIntoView(position, {y: "center"})
      })
      return {handled: true}
    }
    if (command === "restoreViewState") {
      const targetLine = view.state.doc.line(Math.max(1, Math.min(line || 1, view.state.doc.lines)))
      const position = Math.min(targetLine.to, targetLine.from + Math.max(0, (column || 1) - 1))
      view.dispatch({selection: {anchor: position}})
      view.scrollDOM.scrollTop = Math.max(0, scrollTop || 0)
      view.scrollDOM.scrollLeft = Math.max(0, scrollLeft || 0)
      return {handled: true}
    }
    return {handled: false}
  },

  snapshot({documentId, freeze = false}) {
    requireDocument(documentId)
    if (freeze) view.dispatch({effects: editable.reconfigure([EditorView.editable.of(false), EditorState.readOnly.of(true)])})
    return {
      documentId,
      revision: protocol.revision,
      text: view.state.doc.toString(),
      selection: view.state.selection.toJSON()
    }
  }
}

post("ready", {assetVersion: 1})
