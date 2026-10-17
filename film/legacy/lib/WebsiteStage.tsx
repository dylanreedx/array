// The website's demo tree, driven by a state instead of a reducer hook.
//
// Everything visible here is the website's code: DemoStage (MacWorkspace, the tiles, the toast,
// CommandCenter), its CSS modules, and the tokens in production.css. The film adds only the
// stage geometry: the Mac window sits at its native 1380x810 on a 1920x1200 desk. The window
// element is also the Command Center's portal container, with `contain: layout` so the dialog's
// position:fixed resolves to the window and travels with the lens (and stays inside its
// contact-sheet cell) instead of covering the viewport.
//
// commandCenter="frame" portals the Command Center into the part of the stage the lens shows
// instead of the window, drawn at the Mac camera's zoom: a film that holds tight on a zone (and
// zooms the canvas out to give its lens room) would otherwise crop the palette, which sits near
// the window's top edge, and blow it up past the frame. In the frame it sits where the app puts
// it on a screen (centred, FRAME_COMMAND_TOP of the frame height below its top), at the same
// size relative to the tiles as at 100%.
//
// ringScale (output px per app point; 2 = a 2x display) redraws the focus and attention rings at
// the app's own screen weight: MacWorkspace strokes them 1.5 px with a 6/4 dash in canvas px, which
// a lens that magnifies the canvas would otherwise thicken with everything else. Only stroke and
// dash change; the 8 px gap around the tile is geometry and stays the website's.
import '@website/styles/production.css';
import { useRef, type Dispatch } from 'react';
import { DemoStage } from '@website/components/demo/DemoStage';
import type { DemoAction, DemoState } from '@website/features/demo/types';
import { COMMAND_PANEL_TOP, FRAME_COMMAND_TOP, STAGE, WINDOW_ORIGIN } from './formats';
import { useLens } from './Lens';

export { WINDOW_ORIGIN };

export const WebsiteStage: React.FC<{ state: DemoState; dispatch: Dispatch<DemoAction>; gyroPhase: (agentId?: string) => number; commandCenter?: 'window' | 'frame'; ringScale?: number }> = ({ state, dispatch, gyroPhase, commandCenter = 'window', ringScale }) => {
  const windowRef = useRef<HTMLDivElement>(null);
  const frameRef = useRef<HTMLDivElement>(null);
  const lens = useLens();
  const { scale, box } = lens;
  const zoom = state.macCamera.zoom;
  // The framing box (the output minus any caption band) in stage px: the palette centres in it.
  const visible = { x: (box.x - lens.x) / scale, y: (box.y - lens.y) / scale, width: box.width / scale, height: box.height / scale };
  // Stage px the container starts above the box so the panel's own top offset lands at FRAME_COMMAND_TOP of it.
  const lift = COMMAND_PANEL_TOP * zoom - (FRAME_COMMAND_TOP * box.height) / scale;
  const ring = ringScale ? ringScale / scale : 0; // canvas px per app point
  return (
    <div data-film-stage style={{ position: 'absolute', inset: 0, width: STAGE.width, height: STAGE.height, background: '#0b0d10' /* the desk: dark, like the lens, whatever the page theme */ }}>
      {ring > 0 && <style>{`[data-film-stage] [class*="focusRing"], [data-film-stage] [class*="attentionRing"] { stroke-width: ${1.5 * ring}px !important; stroke-dasharray: ${6 * ring}px ${4 * ring}px !important; }`}</style>}
      <div ref={windowRef} style={{ position: 'absolute', left: WINDOW_ORIGIN.x, top: WINDOW_ORIGIN.y, width: STAGE.window.width, height: STAGE.window.height, contain: 'layout' }}>
        <DemoStage state={state} dispatch={dispatch} portalContainer={commandCenter === 'frame' ? frameRef : windowRef} gyroPhase={gyroPhase} />
      </div>
      {commandCenter === 'frame' && <div ref={frameRef} data-film-command-frame style={{ position: 'absolute', left: visible.x, top: visible.y - lift, width: visible.width / zoom, height: (visible.height + lift) / zoom, transform: `scale(${zoom})`, transformOrigin: '0 0', contain: 'layout' }} />}
    </div>
  );
};
