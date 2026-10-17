import { defineVideo } from '../../legacy/lib/sheet';
import { Film } from '../../legacy/lib/Film';
import scene from './scene.json';
import { BPM, timeline } from './timeline';
import type { Scene } from '../../legacy/lib/replay';

export default defineVideo({
  slug: 'canvas-tour',
  title: 'Canvas tour',
  bpm: BPM,
  formats: ['landscape', 'square', 'portrait', 'loop'],
  build: timeline,
  scene: scene as Scene,
  Component: ({ sheet, viewport }) => <Film sheet={sheet} scene={scene as Scene} viewport={viewport} />,
});
