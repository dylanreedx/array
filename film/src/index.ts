import '../kit/determinism'; // first: the page and the no-wall-clock rules, before any video module evaluates
import { registerRoot } from 'remotion';
import { RemotionRoot } from './Root';
registerRoot(RemotionRoot);
