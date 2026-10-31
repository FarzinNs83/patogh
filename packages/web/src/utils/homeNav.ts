/**
 * Which item of the DM sidebar's home block is selected.
 *
 * One function for both items, because the selection is one fact.
 *
 * `/explore` is a page in the main area and wins over a lingering channel id.
 * Anywhere else the Friends view is what shows when no channel is open, and
 * with a channel open neither is selected.
 */

export type HomeNavItem = 'friends' | 'explore';

export function activeHomeNavItem(pathname: string, currentChannelId: string | null): HomeNavItem | null {
  if (pathname === '/explore') return 'explore';
  if (currentChannelId === null) return 'friends';
  return null;
}
