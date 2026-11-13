// Local installed-CLI compatibility probe, no provider request or user config.
// Usage: node scripts/probe-helper-diet-pi.mjs /absolute/path/to/pi-coding-agent
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const packageRoot = process.argv[2];
if (!packageRoot || !path.isAbsolute(packageRoot)) throw new Error('Pass an absolute installed Pi package root.');
const { DefaultResourceLoader } = await import(pathToFileURL(path.join(packageRoot, 'dist/core/resource-loader.js')).href);
const root = fs.mkdtempSync('/tmp/array-diet-loader-');
try {
  const cwd = path.join(root, 'project'), agentDir = path.join(root, 'agent');
  const automatic = path.join(agentDir, 'skills', 'diet-sentinel');
  const explicit = path.join(root, 'explicit-sentinel');
  for (const dir of [cwd, automatic, explicit]) fs.mkdirSync(dir, { recursive: true });
  const skill = name => `---\nname: ${name}\ndescription: Synthetic compatibility sentinel.\n---\nSynthetic task rule.\n`;
  fs.writeFileSync(path.join(automatic, 'SKILL.md'), skill('diet-sentinel'));
  fs.writeFileSync(path.join(explicit, 'SKILL.md'), skill('explicit-sentinel'));
  fs.writeFileSync(path.join(cwd, 'AGENTS.md'), 'PROJECT-HAZARD-SENTINEL\n');
  const observations = [];
  for (const [noSkills, explicitSkill] of [[false, false], [true, false], [true, true]]) {
    const loader = new DefaultResourceLoader({ cwd, agentDir, noSkills,
      noExtensions: true, noPromptTemplates: true, noThemes: true,
      additionalSkillPaths: explicitSkill ? [explicit] : [] });
    await loader.reload({ projectTrusted: true });
    const names = loader.getSkills().skills.map(s => s.name);
    const automaticPresent = names.includes('diet-sentinel');
    const explicitPresent = names.includes('explicit-sentinel');
    const projectHazardPresent = JSON.stringify(loader.getAgentsFiles()).includes('PROJECT-HAZARD-SENTINEL');
    if (automaticPresent === noSkills || explicitPresent !== explicitSkill || !projectHazardPresent)
      throw new Error('Installed Pi changed discovery/explicit-skill/project-context semantics.');
    observations.push({ noSkills, explicitSkill, automaticPresent, explicitPresent, projectHazardPresent });
  }
  console.log(JSON.stringify({ observations }));
} finally { fs.rmSync(root, { recursive: true, force: true }); }
