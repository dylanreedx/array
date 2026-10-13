import type { CSSProperties } from 'react';
import styles from './NativeEditorTile.module.css';

const sourceLines = [
  <><span className={styles.keyword}>import</span> AppKit</>,
  <>&nbsp;</>,
  <span className={styles.comment}>/// The infinite canvas. Tiles live in zones; a zone’s tiles are laid out in</span>,
  <span className={styles.comment}>/// ZONE-LOCAL coordinates and converted to world space at the model boundary.</span>,
  <><span className={styles.keyword}>final class</span> <span className={styles.type}>CanvasNSView</span>: <span className={styles.type}>NSView</span> {'{'}</>,
  <>{'    '}<span className={styles.keyword}>private(set) var</span> viewport = <span className={styles.type}>Viewport</span>(x: <span className={styles.number}>0</span>, y: <span className={styles.number}>0</span>, zoom: <span className={styles.number}>1</span>)</>,
  <>{'    '}<span className={styles.keyword}>private var</span> zoneLayers: [<span className={styles.type}>ZoneLayer</span>] = []</>,
  <>{'    '}<span className={styles.keyword}>private var</span> activeZoneId: <span className={styles.type}>UUID</span>?</>,
  <>&nbsp;</>,
  <>{'    '}<span className={styles.comment}>/// Installs a freshly spawned tile into its zone.</span></>,
  <>{'    '}<span className={styles.comment}>/// One target zone for framing AND install: framing against the armed</span></>,
  <>{'    '}<span className={styles.comment}>/// zone while installing into another displaced the tile by the difference</span></>,
  <>{'    '}<span className={styles.keyword}>func</span> installProjectTile(_ view: <span className={styles.type}>TileView</span>, for tile: <span className={styles.type}>Tile</span>, scope: <span className={styles.type}>CreationScope</span>?) {'{'}</>,
  <>{'        '}<span className={styles.keyword}>let</span> targetId = scope?.zoneId ?? activeZoneId</>,
  <>{'        '}<span className={styles.keyword}>guard let</span> target = zoneLayers.first(where: {'{'} $0.id == targetId {'}'}) <span className={styles.keyword}>else</span> {'{'} <span className={styles.keyword}>return</span> {'}'}</>,
  <>{'        '}<span className={styles.keyword}>let</span> frame = <span className={styles.type}>TilePlacement</span>.frame(for: tile, in: target)</>,
  <>{'        '}install(view, in: target, frame: frame)</>,
  <>{'    '}{'}'}</>,
];

export function NativeEditorTile() {
  return (
    <section className={styles.editor} data-native-editor data-editor-tab="CanvasNSView.swift" aria-label="Swift source editor">
      <div className={styles.codeViewport} data-demo-editor-scroll>
        <div className={styles.codeLines} data-demo-editor-document>
          {sourceLines.map((content, index) => {
            const line = index + 1;
            return (
              <div className={styles.line} data-demo-editor-line={line} key={line} style={{ '--line-index': line } as CSSProperties}>
                <span className={styles.gutter} aria-hidden="true">{line}</span>
                <code className={styles.source}>{content}</code>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}

/** Native titlebar accessory; render inside the parent tile header. */
export function NativeEditorChrome() {
  return (
    <div className={styles.chrome} data-native-editor-chrome aria-hidden="true">
      <span className={styles.chromeIcon}>
        <svg viewBox="0 0 16 16"><path d="M3 4h2m2 0h6M3 8h6m2 0h2M3 12h3m2 0h5" /><circle cx="6" cy="4" r="1" /><circle cx="10" cy="8" r="1" /><circle cx="7" cy="12" r="1" /></svg>
      </span>
      <span className={styles.chromeIcon}>
        <svg viewBox="0 0 16 16"><rect x="2" y="2.5" width="12" height="11" rx="1.6" /><path d="M6 3v10" /></svg>
      </span>
      <span className={styles.filesControl}><svg viewBox="0 0 16 16"><path d="M2.5 3.5h4l1.5 1.6h5.5v7.4h-11z" /></svg>Files</span>
      <span className={styles.language}>SWIFT</span>
    </div>
  );
}

export default NativeEditorTile;
