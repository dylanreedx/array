import assert from "node:assert/strict"
import test from "node:test"
import {RevisionProtocol} from "../src/revision-protocol.mjs"

test("user changes advance from the loaded native revision", () => {
  const protocol = new RevisionProtocol()
  protocol.load("file-a", 7)
  assert.deepEqual(protocol.userChange([{from: 2, to: 2, insert: "x"}]), {
    documentId: "file-a",
    baseRevision: 7,
    revision: 8,
    changes: [{from: 2, to: 2, insert: "x"}]
  })
})

test("stale and cross-document host edits are rejected without mutation", () => {
  const protocol = new RevisionProtocol()
  protocol.load("file-a", 4)
  assert.equal(protocol.acceptHostEdit("file-b", 4, 5).reason, "documentMismatch")
  assert.equal(protocol.acceptHostEdit("file-a", 3, 5).reason, "revisionMismatch")
  assert.equal(protocol.revision, 4)
  assert.deepEqual(protocol.acceptHostEdit("file-a", 4, 9), {accepted: true, revision: 9})
})
