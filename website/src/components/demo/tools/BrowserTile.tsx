import { useEffect, useRef } from 'react';
import type { DemoAction, DemoState } from '../../../features/demo/types';
import { Glyph } from '../Glyph';
import styles from './Tools.module.css';

const pages: Record<string, { title: string; copy: string; links: string[] }> = {
  '/canvas': { title: 'Canvas interaction spec', copy: 'World frames remain stable while zones move and active scope changes.', links: ['/agents', '/companion'] },
  '/agents': { title: 'Agent visibility', copy: 'Working, waiting, failed, or done. Every state stays readable.', links: ['/canvas', '/release'] },
  '/companion': { title: 'Companion handoff', copy: 'A paired phone observes agent activity and resolves approvals.', links: ['/agents', '/release'] },
  '/release': { title: 'Array 0.5', copy: 'Native parity, Safari motion, and Companion approval remain in the release gate.', links: ['/canvas'] }
};

export function BrowserTile({ state, dispatch }: { state: DemoState; dispatch: React.Dispatch<DemoAction> }) {
  const timer = useRef<number | null>(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  const path = state.browser.history[state.browser.index];
  const page = pages[path];
  const navigate = (value: string) => dispatch({ type: 'BROWSER_NAVIGATE', path: value.startsWith('/') ? value : `/${value}` });
  const reload = () => {
    dispatch({ type: 'BROWSER_RELOAD', loading: true });
    timer.current = window.setTimeout(() => dispatch({ type: 'BROWSER_RELOAD', loading: false }), 450);
  };
  return <div className={styles.browser} data-testid="browser-browser">
    <div className={styles.browserBar}>
      <button aria-label="Back" data-interaction-id="browser-back" onClick={() => dispatch({ type: 'BROWSER_HISTORY', direction: -1 })} disabled={state.browser.index === 0}><Glyph name="back" /></button>
      <button aria-label="Forward" data-interaction-id="browser-forward" onClick={() => dispatch({ type: 'BROWSER_HISTORY', direction: 1 })} disabled={state.browser.index === state.browser.history.length - 1}><Glyph name="forward" /></button>
      <button aria-label="Reload" data-interaction-id="browser-reload" onClick={reload} disabled={state.browser.loading}><Glyph name="reload" className={state.browser.loading ? styles.loadingGlyph : undefined} /></button>
      <form onSubmit={(event) => { event.preventDefault(); navigate(state.browser.addressDraft); }}>
        <input aria-label="Browser address" data-interaction-id="browser-address" value={state.browser.addressDraft} onChange={(event) => dispatch({ type: 'BROWSER_DRAFT', value: event.target.value })}/>
      </form>
    </div>
    <div className={styles.browserPage}>
      <span className={styles.browserKicker}>ARRAY INTERNAL</span>
      <h3>{page?.title ?? 'Page not available in this demo'}</h3>
      <p>{page?.copy ?? 'Try /canvas, /agents, /companion, or /release.'}</p>
      {page && <nav aria-label="Demo browser pages">{page.links.map((link) => <button data-interaction-id="browser-page" key={link} onClick={() => navigate(link)}>{link.slice(1)}</button>)}</nav>}
    </div>
  </div>;
}
