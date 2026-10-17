// The registry: every video Remotion can render. A new video is a folder plus one line here
// (scripts/new-video adds the line).
import type { VideoDefinition } from '../kit/sheet';
import boardStory from './board-story';
import fullDay from './full-day';
import powerTour from './power-tour';
import whichTab from './which-tab';

/**
 * Earlier films kept as references (their notes.md says how). They run on legacy/ (the old lib and acts),
 * not on the kit, so they are cast here. hero-loop, what-is-array and canvas-tour are references too, but
 * they replay the website's demo components through seams that never landed on integration, so they are
 * source only and not registered.
 */
const REFERENCES = [boardStory, powerTour, fullDay] as unknown as VideoDefinition[];

export const VIDEOS: readonly VideoDefinition[] = [whichTab, ...REFERENCES];
