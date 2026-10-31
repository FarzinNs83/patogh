import Database from 'better-sqlite3';
import crypto from 'node:crypto';
import type { SpawnedInstance } from './twoInstanceHarness.js';
import { DEFAULT_EVERYONE_PERMISSIONS, permissionsToString } from '@patogh/shared/src/permissions.js';

/**
 * Direct DB insert (test-only): create a space owned by an arbitrary userId.
 * Used by tests #7 and #8 — there is no public path for a replicated stub to
 * become a space owner, so we seed it directly.
 *
 * Note: the spaces table has no `updated_at` or `layout` columns — the plan's
 * INSERT template was incorrect. Only the four required columns are supplied:
 * id, name, owner_id, created_at.
 */
export function seedOwnedSpace(instance: SpawnedInstance, ownerUserId: string, name = 'test-space'): { spaceId: string } {
  const db = new Database(instance.dbPath);
  try {
    db.pragma('journal_mode = WAL');
    // Disable FK checks so we can seed a space owned by a stub user ID that
    // does not yet exist in the users table (the point of this helper).
    db.pragma('foreign_keys = OFF');
    const spaceId = crypto.randomBytes(8).toString('hex');
    const now = Date.now();
    db.prepare(
      `INSERT INTO spaces (id, name, owner_id, created_at)
       VALUES (?, ?, ?, ?)`,
    ).run(spaceId, name, ownerUserId, now);
    return { spaceId };
  } finally {
    db.close();
  }
}

/**
 * Direct DB insert (test-only): a usable extra space — owner membership, a
 * `general` text channel and the @everyone role — for tests that need more than
 * the instance's one main space, which single-space mode never creates by API.
 */
export function seedSpace(instance: SpawnedInstance, ownerUserId: string, name: string): { id: string } {
  const db = new Database(instance.dbPath);
  try {
    db.pragma('journal_mode = WAL');
    const id = crypto.randomBytes(8).toString('hex');
    const now = Date.now();
    db.transaction(() => {
      db.prepare('INSERT INTO spaces (id, name, owner_id, created_at) VALUES (?, ?, ?, ?)').run(id, name, ownerUserId, now);
      db.prepare('INSERT INTO space_members (space_id, user_id, joined_at) VALUES (?, ?, ?)').run(id, ownerUserId, now);
      db.prepare("INSERT INTO channels (id, space_id, name, type, position, created_at) VALUES (?, ?, 'general', 'text', 0, ?)").run(`${id}-general`, id, now);
      db.prepare("INSERT INTO roles (id, space_id, name, color, position, permissions, created_at) VALUES (?, ?, '@everyone', '#b9bbbe', 0, ?, ?)")
        .run(id, id, permissionsToString(DEFAULT_EVERYONE_PERMISSIONS), now);
    })();
    return { id };
  } finally {
    db.close();
  }
}
