/** Database access. Every write here is an idempotent upsert, so re-running
 *  the ingest is always safe and never duplicates a row. */

import pg from 'pg';
import { config } from './config.js';
import type { GatcgCard, GatcgEdition, ResolvedFinish } from './gatcg.js';

export type Db = pg.Pool;

export function connect(): Db {
  return new pg.Pool({
    connectionString: config.databaseUrl,
    max: 4,
    // Supabase's pooler sits behind TLS with a cert our CA store may not carry.
    ssl: config.databaseUrl.includes('supabase.') ? { rejectUnauthorized: false } : undefined,
  });
}

export async function upsertGame(db: Db, slug: string, name: string): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO game (slug, name) VALUES ($1, $2)
     ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
     RETURNING id`,
    [slug, name],
  );
  return rows[0]!.id;
}

export async function upsertSet(
  db: Db,
  gameId: string,
  set: { id: string; prefix: string; name: string; language?: string | null; release_date?: string | null },
): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO card_set (game_id, external_id, prefix, name, language, release_date)
     VALUES ($1, $2, $3, $4, coalesce($5, 'EN'), $6)
     ON CONFLICT (game_id, external_id) DO UPDATE
       SET prefix = EXCLUDED.prefix,
           name = EXCLUDED.name,
           language = EXCLUDED.language,
           release_date = EXCLUDED.release_date,
           updated_at = now()
     RETURNING id`,
    [gameId, set.id, set.prefix, set.name, set.language ?? null, set.release_date ?? null],
  );
  return rows[0]!.id;
}

/** Everything we do not model as a column is kept verbatim in `attributes`. */
const CARD_COLUMN_KEYS = new Set(['uuid', 'slug', 'name', 'editions', 'result_editions']);
const EDITION_COLUMN_KEYS = new Set([
  'uuid', 'slug', 'collector_number', 'rarity', 'illustrator',
  'orientation', 'configuration', 'image', 'set', 'circulationTemplates',
]);

function rest(obj: Record<string, unknown>, exclude: Set<string>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(obj).filter(([k]) => !exclude.has(k)));
}

export async function upsertCard(db: Db, gameId: string, card: GatcgCard): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO card (game_id, external_uuid, slug, name, attributes)
     VALUES ($1, $2, $3, $4, $5::jsonb)
     ON CONFLICT (game_id, external_uuid) DO UPDATE
       SET slug = EXCLUDED.slug,
           name = EXCLUDED.name,
           attributes = EXCLUDED.attributes,
           updated_at = now()
     RETURNING id`,
    [gameId, card.uuid, card.slug, card.name, JSON.stringify(rest(card, CARD_COLUMN_KEYS))],
  );
  return rows[0]!.id;
}

export async function upsertEdition(
  db: Db,
  cardId: string,
  setId: string,
  edition: GatcgEdition,
): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO card_edition (card_id, set_id, external_uuid, slug, collector_number,
                               rarity, illustrator, orientation, configuration,
                               source_image_path, attributes)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb)
     ON CONFLICT (external_uuid) DO UPDATE
       SET card_id = EXCLUDED.card_id,
           set_id = EXCLUDED.set_id,
           slug = EXCLUDED.slug,
           collector_number = EXCLUDED.collector_number,
           rarity = EXCLUDED.rarity,
           illustrator = EXCLUDED.illustrator,
           orientation = EXCLUDED.orientation,
           configuration = EXCLUDED.configuration,
           source_image_path = EXCLUDED.source_image_path,
           attributes = EXCLUDED.attributes,
           updated_at = now()
     RETURNING id`,
    [
      cardId, setId, edition.uuid, edition.slug, edition.collector_number,
      edition.rarity ?? null, edition.illustrator ?? null, edition.orientation ?? null,
      edition.configuration ?? null, edition.image ?? null,
      JSON.stringify(rest(edition, EDITION_COLUMN_KEYS)),
    ],
  );
  return rows[0]!.id;
}

export async function upsertFinishes(
  db: Db,
  editionId: string,
  finishes: ResolvedFinish[],
): Promise<void> {
  for (const f of finishes) {
    await db.query(
      `INSERT INTO card_edition_finish
         (edition_id, finish, external_uuid, label, population, population_operator, is_seeded)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (edition_id, finish) DO UPDATE
         SET external_uuid = EXCLUDED.external_uuid,
             label = EXCLUDED.label,
             population = EXCLUDED.population,
             population_operator = EXCLUDED.population_operator,
             is_seeded = EXCLUDED.is_seeded`,
      [editionId, f.finish, f.externalUuid, f.label, f.population, f.populationOperator, f.isSeeded],
    );
  }
}

export interface PendingImage {
  editionId: string;
  externalUuid: string;
  sourcePath: string;
}

/**
 * Editions with no stored image yet. This is the whole resumability story:
 * a card_image row IS the checkpoint, so an interrupted run simply picks up
 * where it stopped with no extra bookkeeping.
 */
export async function pendingImages(db: Db, variant: string, limit: number | null): Promise<PendingImage[]> {
  const { rows } = await db.query<{ id: string; external_uuid: string; source_image_path: string }>(
    `SELECT e.id, e.external_uuid, e.source_image_path
       FROM card_edition e
       LEFT JOIN card_image i ON i.edition_id = e.id AND i.variant = $1
      WHERE e.source_image_path IS NOT NULL
        AND i.id IS NULL
      ORDER BY e.external_uuid
      ${limit === null ? '' : 'LIMIT ' + Number(limit)}`,
    [variant],
  );
  return rows.map((r) => ({
    editionId: r.id,
    externalUuid: r.external_uuid,
    sourcePath: r.source_image_path,
  }));
}

export async function recordImage(
  db: Db,
  img: {
    editionId: string;
    variant: string;
    storageKey: string;
    contentType: string;
    byteSize: number;
    width: number | null;
    height: number | null;
    sourceUrl: string;
    checksum: string;
  },
): Promise<void> {
  await db.query(
    `INSERT INTO card_image (edition_id, variant, storage_key, content_type, byte_size,
                             width, height, source_url, checksum_sha256)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     ON CONFLICT (edition_id, variant) DO UPDATE
       SET storage_key = EXCLUDED.storage_key,
           content_type = EXCLUDED.content_type,
           byte_size = EXCLUDED.byte_size,
           width = EXCLUDED.width,
           height = EXCLUDED.height,
           checksum_sha256 = EXCLUDED.checksum_sha256,
           fetched_at = now()`,
    [
      img.editionId, img.variant, img.storageKey, img.contentType, img.byteSize,
      img.width, img.height, img.sourceUrl, img.checksum,
    ],
  );
}

export async function startSyncRun(db: Db, gameId: string): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO catalog_sync_run (game_id) VALUES ($1) RETURNING id`,
    [gameId],
  );
  return rows[0]!.id;
}

export async function finishSyncRun(
  db: Db,
  runId: string,
  status: 'succeeded' | 'failed',
  counts: { pages: number; cards: number; editions: number; images: number },
  error?: string,
): Promise<void> {
  await db.query(
    `UPDATE catalog_sync_run
        SET status = $2, finished_at = now(), pages_fetched = $3,
            cards_upserted = $4, editions_upserted = $5, images_fetched = $6, error = $7
      WHERE id = $1`,
    [runId, status, counts.pages, counts.cards, counts.editions, counts.images, error ?? null],
  );
}
