// The agent gyro's phase for a frame, handed to the website through DemoStage's `gyroPhase`, so
// AgentGyro poses itself and never starts its wall-clock Web Animations loop. One cycle is
// GYRO.duration on the website (7.2 s). A looping video (sheet.loop) rounds that to a whole number
// of cycles per loop, so the gyro is in the same pose on the first frame and one past the last.
// Each agent is offset by the app's own per-agent phase (gyroSeedPhase, FNV-1a over the id), so
// tiles do not spin in unison; the gyro renders only while its agent is working.
import { GYRO, gyroSeedPhase } from '@website/components/demo/agent/AgentGyro';
import type { DemoState } from '@website/features/demo/types';
import type { CueSheet } from './sheet';

export const gyroPeriodMs = (sheet: CueSheet) => {
  if (!sheet.loop) return GYRO.duration;
  const loopMs = ((sheet.loop.to - sheet.loop.from) / sheet.clock.fps) * 1000;
  return loopMs / Math.max(1, Math.round(loopMs / GYRO.duration));
};

/** Cycles since the loop's first frame, wrapped to [0, 1): exactly 0 on the first frame and one past the last. */
export const gyroCycle = (sheet: CueSheet, frame: number) => {
  const cycles = (((frame - (sheet.loop?.from ?? 0)) / sheet.clock.fps) * 1000) / gyroPeriodMs(sheet);
  return ((cycles % 1) + 1) % 1;
};

export const makeGyroPhase = (sheet: CueSheet, frame: number, state: DemoState) => {
  const running = gyroCycle(sheet, frame);
  return (agentId?: string) => {
    if (!agentId) return running;
    const offset = gyroSeedPhase(agentId);
    const status = state.agents[agentId]?.status;
    return status === 'working' || status === 'starting' ? (running + offset) % 1 : offset;
  };
};
