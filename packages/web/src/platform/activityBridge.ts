import type { Activity } from '@patogh/shared';
import { useActivityStore } from '../stores/activityStore';

let unsubscribe: (() => void) | null = null;

export function initActivityBridge(): void {
  if (unsubscribe) return; // already initialized
  if (!window.patogh?.onActivityDetected) return; // not Electron

  // Subscribe to future activity changes from main process
  unsubscribe = window.patogh.onActivityDetected((activity) => {
    if (activity) {
      useActivityStore.getState().pushActivities([activity as Activity]);
    } else {
      useActivityStore.getState().pushActivities([]);
    }
  });

  // Request current state (handles instance-switch: game was already running)
  window.patogh.getCurrentActivity?.().then((activity: unknown) => {
    if (activity) {
      useActivityStore.getState().pushActivities([activity as Activity]);
    }
  }).catch(() => {});
}

export function teardownActivityBridge(): void {
  unsubscribe?.();
  unsubscribe = null;
}
