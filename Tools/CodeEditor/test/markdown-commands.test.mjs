import test from 'node:test'
import assert from 'node:assert/strict'
import {EditorState, EditorSelection} from '@codemirror/state'
import {history, undo} from '@codemirror/commands'
import {applyMarkdownCommand} from '../src/markdown-commands.mjs'
function editor(text, selection, readOnly = false) {
  const view = {state: EditorState.create({doc:text, selection, extensions:[history(), EditorState.readOnly.of(readOnly), EditorState.allowMultipleSelections.of(true)]}), focus() {}}
  view.dispatch = change => { view.state = view.state.update(change).state }
  return view
}
test('format Unicode selections with real transactions and undo', () => {
  const view = editor('😀 café', {anchor:0, head:7})
  assert.equal(applyMarkdownCommand(view, 'markdown1'), true)
  assert.equal(view.state.doc.toString(), '**😀 café**')
  assert.equal(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to), '😀 café')
  assert.equal(undo(view), true)
  assert.equal(view.state.doc.toString(), '😀 café')
})
test('format every cursor and toggle selected lines without duplicate edits', () => {
  const view = editor('one\ntwo', EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(4)]))
  applyMarkdownCommand(view, 'markdown2')
  assert.equal(view.state.doc.toString(), '*italic*one\n*italic*two')
  const lines = editor('one\ntwo\n', {anchor:0, head:8})
  applyMarkdownCommand(lines, 'markdown5')
  assert.equal(lines.state.doc.toString(), '- one\n- two\n')
  applyMarkdownCommand(lines, 'markdown5')
  assert.equal(lines.state.doc.toString(), 'one\ntwo\n')
})
test('frozen documents reject formatting', () => {
  const view = editor('keep', {anchor:0, head:4}, true)
  assert.equal(applyMarkdownCommand(view, 'markdown8'), false)
  assert.equal(view.state.doc.toString(), 'keep')
})
