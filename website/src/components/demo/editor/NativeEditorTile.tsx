import type { CSSProperties } from 'react';
import styles from './NativeEditorTile.module.css';

const sourceLines = [
  { sourceLine: 6832, content: <>&nbsp;</> },
  { sourceLine: 6833, content: <><span className={styles.keyword}>if let</span> existing = layer.tileViews[tile.id], existing !== tileView {'{'}</> },
  { sourceLine: 6834, content: <>{'    '}retireTileView(existing)</> },
  { sourceLine: 6835, content: <>{'}'}</> },
  { sourceLine: 6836, content: <><span className={styles.keyword}>var</span> installed = tile</> },
  { sourceLine: 6837, content: <>installed.zoneId = zoneId</> },
  { sourceLine: 6838, content: <>layer.tileViews[tile.id] = tileView</> },
  { sourceLine: 6839, content: <><span className={styles.keyword}>if let</span> index = layer.tiles.firstIndex(where: {'{'} $0.id == tile.id {'}'}) {'{'}</> },
  { sourceLine: 6840, content: <>{'    '}layer.tiles[index] = installed</> },
  { sourceLine: 6841, content: <>{'}'} <span className={styles.keyword}>else</span> {'{'}</> },
  { sourceLine: 6842, content: <>{'    '}layer.tiles.append(installed)</> },
  { sourceLine: 6843, content: <>{'}'}</> },
  { sourceLine: 6844, content: <>adoptTileView(tileView, tileId: tile.id)</> },
  { sourceLine: 6845, content: <><span className={styles.keyword}>_layoutLayerTile</span>(installed, in: layer)</> },
  { sourceLine: 6846, content: <>tileZoneMembership[tile.id] = zoneId</> },
  { sourceLine: 6847, content: <>reorderTileSubviewsByZIndex()</> },
  { sourceLine: 6848, content: <>delegate?.canvasSidebarModelDidChange(self)</> },
  { sourceLine: 6849, content: <span className={styles.comment}>// T7: unconditional, and BEFORE the auto-layout pass. `arrangeAutoLayoutAfterSpawn`</span> },
];

export function NativeEditorTile() {
  return (
    <section className={styles.editor} data-native-editor data-editor-tab="CanvasNSView.swift" aria-label="Swift source editor">
      <div className={styles.codeViewport} data-demo-editor-scroll>
        <div className={styles.codeLines} data-demo-editor-document>
          {sourceLines.map(({ content, sourceLine }, index) => {
            const line = index + 1;
            return (
              <div className={styles.line} data-demo-editor-line={line} data-source-line={sourceLine} key={sourceLine} style={{ '--line-index': line } as CSSProperties}>
                <span className={styles.gutter} aria-hidden="true">{sourceLine}</span>
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
