import styles from './companion.module.css';

interface Props { pairedMacName: string; freshnessLabel: string }

export function Settings({ pairedMacName, freshnessLabel }: Props) {
  return (
    <div className={styles.settings}>
      <section className={styles.pairedCard} aria-labelledby="paired-mac-title">
        <span className={styles.macGlyph} aria-hidden="true"><i></i></span>
        <div><small>Paired Mac</small><h3 id="paired-mac-title">{pairedMacName}</h3><p><span aria-hidden="true">●</span> Live · {freshnessLabel}</p></div>
      </section>
      <dl className={styles.settingsList}>
        <div><dt>Workspace</dt><dd>Array website</dd></div>
        <div><dt>Connection</dt><dd>Local secure session</dd></div>
        <div><dt>Authorized scope</dt><dd>Agents, transcripts, and approvals</dd></div>
        <div><dt>Canvas</dt><dd>Read only, with local focus</dd></div>
        <div><dt>Tile editing</dt><dd>Continue on Mac</dd></div>
        <div><dt>Last synchronization</dt><dd>{freshnessLabel}</dd></div>
      </dl>
      <p className={styles.settingsFootnote}>Companion mirrors agent activity and approvals from the paired Mac. Workspace editing remains on Mac.</p>
    </div>
  );
}
