export class RevisionProtocol {
  constructor() {
    this.documentId = null
    this.revision = 0
  }

  load(documentId, revision) {
    if (typeof documentId !== "string" || !documentId) throw new Error("documentId is required")
    if (!Number.isSafeInteger(revision) || revision < 0) throw new Error("revision must be a nonnegative safe integer")
    this.documentId = documentId
    this.revision = revision
  }

  userChange(changes) {
    if (!this.documentId) throw new Error("no document loaded")
    const baseRevision = this.revision
    this.revision += 1
    return {documentId: this.documentId, baseRevision, revision: this.revision, changes}
  }

  acceptHostEdit(documentId, expectedRevision, nextRevision) {
    if (documentId !== this.documentId) return {accepted: false, reason: "documentMismatch", revision: this.revision}
    if (expectedRevision !== this.revision) return {accepted: false, reason: "revisionMismatch", revision: this.revision}
    if (!Number.isSafeInteger(nextRevision) || nextRevision <= expectedRevision) {
      return {accepted: false, reason: "invalidNextRevision", revision: this.revision}
    }
    this.revision = nextRevision
    return {accepted: true, revision: this.revision}
  }
}
