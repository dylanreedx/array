import { defineCollection } from 'astro:content';
import { z } from 'astro/zod';
import { glob } from 'astro/loaders';

const docs = defineCollection({
  loader: glob({ pattern: '*.md', base: '../docs/user' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    section: z.enum(['Start here', 'Workspace', 'Agents', 'Reference']),
    order: z.number(),
  }),
});

export const collections = { docs };
