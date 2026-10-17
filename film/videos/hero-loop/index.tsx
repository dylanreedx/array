import { defineVideo } from '../../legacy/lib/sheet';
import { Film } from '../../legacy/lib/Film';
import scene from './scene.json';
import { BPM, timeline } from './timeline';
import type { Scene } from '../../legacy/lib/replay';

export default defineVideo({
  slug: 'hero-loop',
  title: 'Hero loop',
  bpm: BPM,
  formats: ['loop', 'square', 'loop60'],
  build: timeline,
  scene: scene as Scene,
  Component: ({ sheet, viewport }) => <Film sheet={sheet} scene={scene as Scene} captions={false} viewport={viewport} commandCenter="frame" ringScale={2} />,
});
