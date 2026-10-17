// Remotion's webpack config emits imported images as asset URLs.
declare module '*.svg' { const url: string; export default url; }
