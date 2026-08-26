import type { KeyboardEvent } from 'react';
import type { CompanionTab } from '../../../features/demo/types';
import styles from './companion.module.css';
import { Glyph, type GlyphName } from '../Glyph';

const tabs: Array<{ id: CompanionTab; label: string; glyph: GlyphName }> = [
  { id: 'agents', label: 'Agents', glyph: 'people' },
  { id: 'canvas', label: 'Canvas', glyph: 'grid' },
  { id: 'approvals', label: 'Approvals', glyph: 'approval' },
  { id: 'settings', label: 'Settings', glyph: 'settings' }
];

interface Props {
  active: CompanionTab;
  pendingApprovals: number;
  onChange: (tab: CompanionTab) => void;
}

export function CompanionTabs({ active, pendingApprovals, onChange }: Props) {
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const current = tabs.findIndex((tab) => tab.id === active);
    let next = current;
    if (event.key === 'ArrowRight') next = (current + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') next = (current - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    else return;
    event.preventDefault();
    onChange(tabs[next].id);
    requestAnimationFrame(() => document.getElementById(`companion-tab-${tabs[next].id}`)?.focus());
  };

  return (
    <div className={styles.tabs} role="tablist" aria-label="Companion views" data-testid="companion-tabs" onKeyDown={onKeyDown}>
      {tabs.map((tab) => (
        <button
          className={active === tab.id ? styles.tabActive : styles.tab}
          id={`companion-tab-${tab.id}`}
          key={tab.id}
          type="button"
          role="tab"
          aria-selected={active === tab.id}
          aria-controls={`companion-panel-${tab.id}`}
          tabIndex={active === tab.id ? 0 : -1}
          data-testid={`companion-tab-${tab.id}`}
          data-interaction-id={`companion-tab-${tab.id}`}
          onClick={() => onChange(tab.id)}
        >
          <span className={styles.tabIconWell} aria-hidden="true">
            <Glyph className={styles.tabGlyph} name={tab.glyph} />
          </span>
          <span className={styles.tabLabel}>{tab.label}</span>
          {tab.id === 'approvals' && pendingApprovals > 0 && <b className={styles.badge}>{pendingApprovals}</b>}
        </button>
      ))}
    </div>
  );
}
