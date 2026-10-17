// Composition registry: one <Composition> per (video, format), ids like `which-tab--landscape`, plus each
// video's `--sub` (motion-blur sub-frames, kit/blur.tsx) and `--og`, and the review `sheet`.
// calculateMetadata builds the cue sheet at the format's fps only to read its duration; the sheet itself is
// NOT a prop (Remotion serialises props to JSON, and a sheet holds functions), so the component rebuilds it.
import { useMemo } from 'react';
import { Composition, Folder, Freeze, useCurrentFrame, type CalculateMetadataFunction } from 'remotion';
import { subframes } from '../kit/blur';
import { makeClock } from '../kit/clock';
import { ContactSheet, makeSheetMetadata, type SheetProps } from '../kit/ContactSheet';
import { FORMATS, type FormatId } from '../kit/formats';
import type { VideoDefinition } from '../kit/sheet';
import { VIDEOS } from '../videos';

type Props = { slug: string; format: FormatId };

const bySlug = (slug: string) => VIDEOS.find((v) => v.slug === slug) as VideoDefinition;
const sheetOf = (v: VideoDefinition, format: FormatId) => v.build(makeClock({ fps: FORMATS[format].fps, bpm: v.bpm }));

const metadata: CalculateMetadataFunction<Props> = ({ props }) => {
  const f = FORMATS[props.format];
  return { durationInFrames: sheetOf(bySlug(props.slug), props.format).durationInFrames, fps: f.fps, width: f.width, height: f.height };
};

const Render: React.FC<Props> = ({ slug, format }) => {
  const v = bySlug(slug);
  const sheet = useMemo(() => sheetOf(v, format), [v, format]);
  return <v.Component sheet={sheet} format={format} />;
};

// The landscape master as a stream of motion-blur sub-frames (scripts/render --blur).
type SubProps = { slug: string; groups: number[] };
const subMetadata: CalculateMetadataFunction<SubProps> = ({ props }) => ({ durationInFrames: Math.max(1, subframes(sheetOf(bySlug(props.slug), 'landscape'), props.groups).length) });
const Sub: React.FC<SubProps> = ({ slug, groups }) => {
  const j = useCurrentFrame();
  const v = bySlug(slug);
  const sheet = useMemo(() => sheetOf(v, 'landscape'), [v]);
  const subs = useMemo(() => subframes(sheet, groups), [sheet, groups]);
  const s = subs[Math.min(j, subs.length - 1)];
  return <Freeze frame={s.t}><v.Component sheet={sheet} /></Freeze>;
};

export const RemotionRoot: React.FC = () => (
  <>
    {VIDEOS.map((v) => (
      <Folder key={v.slug} name={v.slug}>
        {v.formats.map((format) => (
          <Composition key={format} id={`${v.slug}--${format}`} component={Render} defaultProps={{ slug: v.slug, format } as Props} calculateMetadata={metadata}
            durationInFrames={1} fps={FORMATS[format].fps} width={FORMATS[format].width} height={FORMATS[format].height} />
        ))}
        <Composition id={`${v.slug}--sub`} component={Sub} defaultProps={{ slug: v.slug, groups: [] as number[] }} calculateMetadata={subMetadata} durationInFrames={1} fps={FORMATS.landscape.fps} width={FORMATS.landscape.width} height={FORMATS.landscape.height} />
        {/* full-length, not a <Still>, so the OG card can be any frame */}
        <Composition id={`${v.slug}--og`} component={Render} defaultProps={{ slug: v.slug, format: 'og' } as Props} calculateMetadata={metadata} durationInFrames={1} fps={FORMATS.og.fps} width={FORMATS.og.width} height={FORMATS.og.height} />
      </Folder>
    ))}
    <Composition id="sheet" component={(p: SheetProps) => <ContactSheet {...p} videos={VIDEOS} />} defaultProps={{ slug: VIDEOS[0].slug, every: 30 } as SheetProps} calculateMetadata={makeSheetMetadata(VIDEOS)} durationInFrames={1} fps={60} width={1940} height={1100} />
  </>
);
