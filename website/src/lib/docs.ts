import { getCollection } from 'astro:content';

export const docSections = ['Start here', 'Workspace', 'Agents', 'Reference'] as const;
export async function getDocs() {
  return (await getCollection('docs')).sort((a, b) => a.data.order - b.data.order);
}
export const docURL = (id: string) => `/docs/${id}/`;
