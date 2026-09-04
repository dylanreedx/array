import test from 'node:test'
import assert from 'node:assert/strict'
import {defaultPreferences, normalizePreferences} from '../src/preferences.mjs'
test('editor defaults are explicit and Vim is opt-in', () => {
  assert.deepEqual(normalizePreferences(), defaultPreferences)
  assert.equal(defaultPreferences.vimEnabled, false)
})
test('partial updates retain prior choices and bound typography', () => {
  const previous = normalizePreferences({vimEnabled: true, appearance: 'dark', fontSize: 18})
  assert.equal(normalizePreferences({wordWrap: true}, previous).vimEnabled, true)
  assert.equal(normalizePreferences({wordWrap: true}, previous).fontSize, 18)
  assert.equal(normalizePreferences({fontSize: 200}).fontSize, 32)
  assert.equal(normalizePreferences({lineHeight: -1}).lineHeight, 1.1)
  assert.equal(normalizePreferences({vimEnabled: 'true'}).vimEnabled, false)
})
