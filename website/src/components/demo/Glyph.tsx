import type { SVGProps } from 'react';
export type GlyphName='more'|'tool'|'terminal'|'expand'|'collapse'|'send'|'back'|'forward'|'reload'|'close'|'fit'|'command'|'note'|'browser'|'zone'|'shuffle'|'reset'|'agent'|'check'|'attention'|'chevronDown'|'cursor'|'people'|'grid'|'approval'|'settings';
export interface GlyphProps extends Omit<SVGProps<SVGSVGElement>,'children'>{name:GlyphName}
export function Glyph({name,...props}:GlyphProps){const common={fill:'none',stroke:'currentColor',strokeWidth:1.5,strokeLinecap:'round' as const,strokeLinejoin:'round' as const};return <svg viewBox="0 0 16 16" width="1em" height="1em" aria-hidden="true" focusable="false" {...common} {...props}>
  {name==='more'&&<><circle cx="3" cy="8" r=".75" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r=".75" fill="currentColor" stroke="none"/><circle cx="13" cy="8" r=".75" fill="currentColor" stroke="none"/></>}
  {name==='tool'&&<path d="M9.7 2.6a3 3 0 0 0-3.8 3.8L2.7 9.6a1.9 1.9 0 0 0 2.7 2.7l3.2-3.2a3 3 0 0 0 3.8-3.8L10.5 7.2 8.8 5.5l1.9-1.9Z"/>}
  {name==='terminal'&&<><rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2"/><path d="m4.5 6 2 2-2 2M8.5 10h3"/></>}
  {name==='expand'&&<path d="M4 8h8M8 4v8"/>}{name==='collapse'&&<path d="M4 8h8"/>}
  {name==='send'&&<path d="M8 13V3m0 0L4.5 6.5M8 3l3.5 3.5"/>}{name==='back'&&<path d="m10 3-5 5 5 5"/>}{name==='forward'&&<path d="m6 3 5 5-5 5"/>}
  {name==='reload'&&<><path d="M12.4 5.5A5 5 0 1 0 13 9"/><path d="M9.8 5.5h2.7V2.8"/></>}
  {name==='close'&&<path d="m4 4 8 8m0-8-8 8"/>}
  {name==='fit'&&<path d="M6 3H3v3m7-3h3v3M6 13H3v-3m7 3h3v-3"/>}
  {name==='command'&&<path d="M5.25 5.5H4a2 2 0 1 1 2-2v9a2 2 0 1 1-2-2h8a2 2 0 1 1-2 2v-9a2 2 0 1 1 2 2H5.25Z"/>}
  {name==='note'&&<><rect x="3" y="2" width="10" height="12" rx="1.5"/><path d="M5.5 5.5h5M5.5 8h5M5.5 10.5h3.5"/></>}
  {name==='browser'&&<><rect x="1.75" y="2.5" width="12.5" height="11" rx="2"/><path d="M2 5.5h12M4 4h.01M6 4h.01"/></>}
  {name==='zone'&&<rect x="2.5" y="2.5" width="11" height="11" rx="2" strokeDasharray="2 2"/>}
  {name==='shuffle'&&<><path d="M2.5 4.5h2c3.5 0 3.5 7 7 7h2"/><path d="m11.5 9.5 2 2-2 2M2.5 11.5h2c1.2 0 2-.8 2.7-1.8M9 6.2c.7-1 1.5-1.7 2.5-1.7h2m-2-2 2 2-2 2"/></>}
  {name==='reset'&&<><path d="M3.3 5.5A5.25 5.25 0 1 1 3 10"/><path d="M3.3 2.5v3h3"/></>}
  {name==='agent'&&<><circle cx="8" cy="8" r="2.25"/><path d="M8 2.5v2M8 11.5v2M2.5 8h2M11.5 8h2"/></>}
  {name==='check'&&<path d="m3.5 8 3 3 6-6"/>}
  {name==='attention'&&<><path d="M8 3v6"/><circle cx="8" cy="12" r=".6" fill="currentColor" stroke="none"/></>}
  {name==='chevronDown'&&<path d="m4 6 4 4 4-4"/>}
  {name==='cursor'&&<path d="M3 2.5 12.2 8l-4 .9-1.9 3.6L3 2.5Z"/>}
  {name==='people'&&<><path d="M6.2 7.2a2.25 2.25 0 1 0 0-4.5 2.25 2.25 0 0 0 0 4.5Z" fill="currentColor" stroke="none"/><path d="M1.9 12.8c.2-2.45 1.6-3.8 4.3-3.8s4.1 1.35 4.3 3.8" fill="currentColor" stroke="none"/><path d="M10.15 7.1a1.85 1.85 0 1 0 0-3.7M10.45 9.1c2.2.12 3.38 1.35 3.55 3.45"/></>}
  {name==='grid'&&<><rect x="2.1" y="2.1" width="4.75" height="4.75" rx="1.05" fill="currentColor" stroke="none"/><rect x="9.15" y="2.1" width="4.75" height="4.75" rx="1.05" fill="currentColor" stroke="none"/><rect x="2.1" y="9.15" width="4.75" height="4.75" rx="1.05" fill="currentColor" stroke="none"/><rect x="9.15" y="9.15" width="4.75" height="4.75" rx="1.05" fill="currentColor" stroke="none"/></>}
  {name==='approval'&&<><path d="M8 1.75c.65 0 1.12.75 1.7.98.6.25 1.47.05 1.92.5.45.45.25 1.32.5 1.92.23.58.98 1.05.98 1.7s-.75 1.12-.98 1.7c-.25.6-.05 1.47-.5 1.92-.45.45-1.32.25-1.92.5-.58.23-1.05.98-1.7.98s-1.12-.75-1.7-.98c-.6-.25-1.47-.05-1.92-.5-.45-.45-.25-1.32-.5-1.92-.23-.58-.98-1.05-.98-1.7s.75-1.12.98-1.7c.25-.6.05-1.47.5-1.92.45-.45 1.32-.25 1.92-.5.58-.23 1.05-.98 1.7-.98Z"/><path d="m5.4 7.9 1.65 1.65 3.45-3.6"/></>}
  {name==='settings'&&<><path d="M6.8 2.05h2.4l.35 1.45c.35.13.68.32.98.56l1.43-.45 1.2 2.08-1.08 1c.03.2.05.42.05.64s-.02.43-.05.64l1.08 1-1.2 2.08-1.43-.45c-.3.24-.63.43-.98.56l-.35 1.45H6.8l-.35-1.45a4.4 4.4 0 0 1-.98-.56l-1.43.45-1.2-2.08 1.08-1a4.5 4.5 0 0 1 0-1.28l-1.08-1 1.2-2.08 1.43.45c.3-.24.63-.43.98-.56l.35-1.45Z"/><circle cx="8" cy="7.33" r="1.75"/></>}
</svg>}
