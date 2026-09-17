import type { Entity } from './types';

/**
 * Describes each syncable table so push/pull can be written once instead of
 * four times. `fields` are the columns a client is allowed to set; everything
 * else (uid, server_seq) is server-owned.
 */
export interface TableSpec {
  table: string;
  fields: readonly string[];
  /** Columns that must be present and non-empty on an insert. */
  required: readonly string[];
  /**
   * Values used when inserting a tombstone for a record the server has never
   * seen — which happens whenever a device creates and deletes a block while
   * offline and only ever syncs the delete. SQLite validates NOT NULL on the
   * proposed row *before* ON CONFLICT resolution, so these cannot be omitted.
   */
  tombstone: Record<string, string | number | null>;
}

export const TABLES: Record<Entity, TableSpec> = {
  note: {
    table: 'notes',
    fields: ['title', 'icon', 'parent_id', 'order_key'],
    required: ['order_key'],
    tombstone: { title: '', icon: null, parent_id: null, order_key: '' },
  },
  block: {
    table: 'blocks',
    fields: ['note_id', 'parent_id', 'order_key', 'type', 'content'],
    required: ['note_id', 'order_key', 'type', 'content'],
    tombstone: { note_id: '', parent_id: null, order_key: '', type: 'paragraph', content: '{}' },
  },
  theme: {
    table: 'themes',
    fields: ['name', 'spec'],
    required: ['name', 'spec'],
    tombstone: { name: '', spec: '{}' },
  },
  attachment: {
    table: 'attachments',
    fields: ['note_id', 'r2_key', 'mime', 'size'],
    required: ['r2_key', 'mime', 'size'],
    tombstone: { note_id: null, r2_key: '', mime: '', size: 0 },
  },
};

export const BLOCK_TYPES = new Set([
  'paragraph', 'heading1', 'heading2', 'heading3',
  'todo', 'bullet', 'numbered', 'quote', 'code', 'divider', 'image',
]);

/** Guard-rails that keep one device from writing a row big enough to break sync. */
export const LIMITS = {
  maxChangesPerPush: 500,
  maxPullPageSize: 500,
  defaultPullPageSize: 200,
  maxIdLength: 64,
  maxTitleLength: 512,
  maxOrderKeyLength: 256,
  maxBlockContentBytes: 64 * 1024,
  maxThemeSpecBytes: 32 * 1024,
  maxAttachmentBytes: 25 * 1024 * 1024,
} as const;
