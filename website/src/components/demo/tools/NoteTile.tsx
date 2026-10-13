import type { DemoAction, DemoState } from '../../../features/demo/types';
import styles from './Tools.module.css';

const labels = ['Verify zone placement', 'Approve Companion handoff', 'Run Safari motion pass'];
export function NoteTile({ state, dispatch, title = 'Array 0.5', checklist = labels }: { state: DemoState; dispatch: React.Dispatch<DemoAction>; title?: string; checklist?: string[] }) {
  return <div className={styles.note} data-testid="note-note">
    <div className={styles.noteModes} role="group" aria-label="Note display mode">
      <button data-interaction-id="note-edit" aria-pressed={state.note.mode === 'edit'} onClick={() => dispatch({ type: 'NOTE_MODE', mode: 'edit' })}>Edit</button>
      <button data-interaction-id="note-preview" aria-pressed={state.note.mode === 'preview'} onClick={() => dispatch({ type: 'NOTE_MODE', mode: 'preview' })}>Preview</button>
    </div>
    {state.note.mode === 'edit' ? <>
      <textarea aria-label="Note Markdown" data-interaction-id="note-input" value={state.note.draft} onChange={(event) => dispatch({ type: 'NOTE_DRAFT', value: event.target.value })}/>
      <div className={styles.noteActions}><button data-interaction-id="note-cancel" onClick={() => dispatch({ type: 'NOTE_CANCEL' })}>Cancel</button><button data-interaction-id="note-done" onClick={() => dispatch({ type: 'NOTE_COMMIT' })}>Done</button></div>
    </> : <div className={styles.notePreview}><strong>{title}</strong>{checklist.map((label, index) => <label key={label}><input type="checkbox" data-interaction-id="note-check" checked={state.note.checks[index]} onChange={() => dispatch({ type: 'NOTE_CHECK', index })}/><span>{label}</span></label>)}</div>}
  </div>;
}
