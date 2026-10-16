import { TOOLBAR, TOOLBAR_ITEMS, TOOLBAR_LAYOUT, TOOLBAR_MENUS, type ToolbarItemId } from '../../../lib/guided-toolbar';
import styles from './CanvasToolbar.module.css';

// SF Symbols the app's toolbar uses, drawn to the same 15pt medium weight:
// square.dashed, sparkles, terminal, note.text, rectangle.split.3x1, globe,
// doc.text, folder, plusminus.
function ToolbarIcon({ id }: { id: ToolbarItemId }) {
  return (
    <svg viewBox="0 0 18 18" aria-hidden="true" focusable="false">
      {id === 'zone' && <rect x="2.75" y="2.75" width="12.5" height="12.5" rx="2.6" strokeDasharray="2.4 2.1" />}
      {id === 'agent' && <><path d="M7.6 2.6 8.9 6.3l3.7 1.3-3.7 1.3-1.3 3.7-1.3-3.7-3.7-1.3 3.7-1.3Z" /><path d="m13.4 10.6.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6Z" /></>}
      {id === 'terminal' && <><rect x="2.25" y="3.25" width="13.5" height="11.5" rx="2.4" /><path d="m5.4 7 2 2-2 2M9.2 11h3.4" /></>}
      {id === 'note' && <><rect x="3.5" y="2.25" width="11" height="13.5" rx="2.2" /><path d="M6.2 6h5.6M6.2 9h5.6M6.2 12h3.6" /></>}
      {id === 'board' && <><rect x="2.25" y="3.75" width="13.5" height="10.5" rx="2.2" /><path d="M6.75 3.75v10.5M11.25 3.75v10.5" /></>}
      {id === 'browser' && <><circle cx="9" cy="9" r="6.5" /><ellipse cx="9" cy="9" rx="2.7" ry="6.5" /><path d="M2.6 9h12.8" /></>}
      {id === 'editor' && <><path d="M4 2.25h6.3l3.7 3.7v9.8H4Z" /><path d="M10.2 2.4v3.7h3.7M6.5 9.2h5M6.5 12h5" /></>}
      {id === 'fileTree' && <path d="M2.25 4.6V3.5c0-.6.4-1 1-1h3.6l1.6 1.8h6.3c.6 0 1 .4 1 1v8.9c0 .6-.4 1-1 1H3.25c-.6 0-1-.4-1-1Z" />}
      {id === 'diff' && <path d="M9 2.75v6.5M5.75 6h6.5M5.75 14.25h6.5" />}
    </svg>
  );
}

/**
 * The app's creation toolbar, in the canvas. The guided controller places the
 * bar (pivot + angle), lights the hovered button, and opens the pill or menu.
 */
export function CanvasToolbar() {
  let lastGroup: number | null = null;
  return (
    <div className={styles.layer} data-demo-toolbar data-edge="bottom" aria-hidden="true">
      <div className={styles.bar} data-demo-toolbar-bar
        style={{ width: TOOLBAR_LAYOUT.length, height: TOOLBAR.thickness, marginLeft: -TOOLBAR_LAYOUT.length / 2, marginTop: -TOOLBAR.thickness / 2 }}>
        {TOOLBAR_ITEMS.map(item => {
          const divider = lastGroup !== null && lastGroup !== item.group;
          lastGroup = item.group;
          return [
            divider && <span key={`${item.id}-divider`} className={styles.divider} />,
            <span key={item.id} className={styles.button} data-toolbar-item={item.id} data-state="rest">
              <span className={styles.upright}>
                <ToolbarIcon id={item.id} />
                {item.choices && <svg className={styles.chevron} viewBox="0 0 8 8" aria-hidden="true"><path d="m1.6 2.9 2.4 2.4 2.4-2.4" /></svg>}
              </span>
            </span>,
          ];
        })}
      </div>
      {TOOLBAR_ITEMS.map(item => (
        <span key={item.id} className={styles.pill} data-toolbar-pill={item.id} hidden>
          {item.title}{item.shortcut && <kbd>{item.shortcut}</kbd>}
        </span>
      ))}
      {Object.entries(TOOLBAR_MENUS).map(([kind, menu]) => (
        <div key={kind} className={styles.menu} data-toolbar-menu={kind} data-open="false">
          <p>{menu.title}</p>
          {menu.rows.map(row => <span key={row} data-toolbar-choice={row} data-highlighted="false">{row}</span>)}
        </div>
      ))}
    </div>
  );
}
