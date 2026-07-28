Should the writer-side duplicate check be a precondition or a thrown error? A precondition
halts the indexer on a bug; a thrown error lets the caller decide.
choices: precondition, thrown error, both behind a flag
