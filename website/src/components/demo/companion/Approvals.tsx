import type { Approval } from '../../../features/demo/types';
import styles from './companion.module.css';

interface Props {
  approval: Approval;
  onResolve: (decision: 'accept' | 'decline') => void;
}

export function Approvals({ approval, onResolve }: Props) {
  if (approval.state === 'accepted' || approval.state === 'declined') {
    return (
      <div className={styles.approvalEmpty}>
        <span aria-hidden="true">✓</span>
        <h3>{approval.state === 'accepted' ? 'Approval sent' : 'Request declined'}</h3>
        <p>The paired Mac workspace has already been updated.</p>
      </div>
    );
  }

  return (
    <div className={styles.approvals}>
      <article className={styles.approvalCard} aria-labelledby={`approval-title-${approval.id}`}>
        <span className={styles.approvalGlyph} aria-hidden="true">◆</span>
        <small>{approval.state === 'error' ? 'Could not send response' : approval.state === 'resolving' ? 'Sending response…' : 'Approval requested'}</small>
        <h3 id={`approval-title-${approval.id}`}>{approval.title}</h3>
        <p>{approval.detail}</p>
        <div className={styles.approvalMeta}><span>Verify approval handoff</span><span>just now</span></div>
        <div className={styles.approvalActions}>
          <button type="button" disabled={approval.state === 'resolving'} data-testid="approval-deny" data-interaction-id="approval-deny" onClick={() => onResolve('decline')}>Deny</button>
          <button type="button" disabled={approval.state === 'resolving'} data-testid="approval-approve" data-interaction-id="approval-approve" onClick={() => onResolve('accept')}>{approval.state === 'resolving' ? 'Sending…' : approval.state === 'error' ? 'Retry approval' : 'Approve'}</button>
        </div>
      </article>
    </div>
  );
}
