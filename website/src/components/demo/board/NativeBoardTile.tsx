import styles from './NativeBoardTile.module.css';

type CardState = 'queued' | 'active' | 'done';

const lanes: { id: string; name: string; cards: { id?: string; title: string; meta?: string; state?: CardState }[] }[] = [
  {
    id: 'todo', name: 'To Do', cards: [
      { id: 'placement', title: 'Move tiles into the project zone', meta: 'Notes', state: 'queued' },
      { title: 'Snap zones to the grid' },
      { title: 'Check pinch zoom at 400%' },
    ],
  },
  {
    id: 'doing', name: 'Doing', cards: [
      { id: 'approval', title: 'Review the placement change', state: 'queued' },
    ],
  },
  {
    id: 'done', name: 'Done', cards: [
      { id: 'tests', title: 'Run canvas geometry checks', meta: '1 linked', state: 'queued' },
      { title: 'Keep the project zone in view' },
    ],
  },
];

function AssignIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="8" cy="8" r="6.1" />
      <circle cx="8" cy="6.2" r="1.8" />
      <path d="M4.9 11.7c.5-1.4 1.5-2.1 3.1-2.1s2.6.7 3.1 2.1" />
    </svg>
  );
}

function Grip() {
  return <span className={styles.grip} aria-hidden="true">⠿</span>;
}

export function NativeBoardTile() {
  return (
    <section className={styles.board} data-native-board aria-label="Canvas sprint board">
      <div className={styles.lanes}>
        {lanes.map((lane) => (
          <section className={styles.lane} key={lane.id} aria-label={`${lane.name}, ${lane.cards.length} tasks`}>
            <header className={styles.laneHeader}>
              <h3>{lane.name}</h3>
              <span className={styles.count}>{lane.cards.length}</span>
            </header>
            <div className={styles.cards}>
              {lane.cards.map((card, index) => (
                <article
                  className={styles.card}
                  key={card.id ?? `${lane.id}-${index}`}
                  data-demo-board-card={card.id}
                  data-demo-state={card.state}
                >
                  <Grip />
                  <p className={styles.cardTitle}>{card.title}</p>
                  {card.meta && <span className={styles.meta}>{card.meta}</span>}
                  <div className={styles.assignee}><AssignIcon /><span>Assign agent</span><span className={styles.chevrons}>⌃⌄</span></div>
                </article>
              ))}
              <div className={styles.addTask} aria-hidden="true"><span>＋</span> Add task</div>
            </div>
          </section>
        ))}
      </div>

      <footer className={styles.footer}>Drag a task onto an agent to assign it&nbsp; · &nbsp;Click to open details</footer>
    </section>
  );
}

/** The board's single title-bar add action; lane-level add rows remain below. */
export function NativeBoardChrome() {
  return <span className={styles.titleBarAdd} data-native-board-chrome aria-hidden="true">+</span>;
}

/** Task details lives at the canvas level, like the native child window. */
export function NativeBoardDetails() {
  return (
    <section className={styles.detailBackdrop} data-demo-board-detail hidden aria-hidden="true" aria-label="Task details">
      <div className={styles.detail} role="dialog" aria-modal="true" aria-label="Task details">
        <header className={styles.detailHeader}>
          <span>TASK DETAILS</span><span className={styles.saved}>Saved</span><span className={styles.close}>×</span>
        </header>
        <div className={styles.detailBody}>
          <section className={styles.document} aria-label="Task description">
            <h2>Move tiles into the project zone</h2>
            <div className={styles.sectionLabel}>Description</div>
            <div className={styles.formatBar} aria-hidden="true">
              <b>B</b><i>I</i><s>S</s><span />
              <span className={styles.formatButton}>H</span>
              <span className={styles.formatButton}>• List</span>
              <span className={styles.formatButton}>1. List</span>
              <span className={styles.formatButton}>☑ Checklist</span>
              <span className={styles.formatButton}>❝</span>
              <span className={styles.formatButton}>&lt;/&gt;</span>
              <span className={styles.formatButton}>Link</span>
              <span className={styles.formatButton}>Image</span>
            </div>
            <div className={styles.description}>
              <p>Keep the canvas tiles aligned with the active Array project zone.</p>
              <ul>
                <li><span className={styles.checked}>✓</span> Confirm the Array zone is active</li>
                <li><span className={styles.check} /> Keep three tile positions aligned</li>
                <li><span className={styles.check} /> Pass the canvas geometry checks</li>
              </ul>
            </div>
          </section>
          <aside className={styles.detailAside}>
            <div className={styles.sectionLabel}>Status</div><div className={styles.select}>To Do <span>⌃⌄</span></div>
            <div className={styles.sectionLabel}>Assignee</div><div className={styles.select}>Assign agent <span>⌃⌄</span></div>
            <p>The task appears in the assigned agent’s prompt box. Sending stays explicit.</p>
          </aside>
        </div>
      </div>
    </section>
  );
}

export default NativeBoardTile;
