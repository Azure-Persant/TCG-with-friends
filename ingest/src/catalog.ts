/** Phase 1: crawl the catalog JSON into our tables. Fast -- 45 pages. */

import { config } from './config.js';
import * as db from './db.js';
import { GatcgClient, resolveFinishes } from './gatcg.js';
import type { PoliteClient } from './http.js';

export interface CatalogResult {
  pages: number;
  cards: number;
  editions: number;
  seededFinishes: number;
}

export async function ingestCatalog(
  pool: db.Db,
  http: PoliteClient,
  log: (msg: string) => void,
): Promise<CatalogResult> {
  const client = new GatcgClient(http);
  const gameId = await db.upsertGame(pool, config.game.slug, config.game.name);
  const runId = await db.startSyncRun(pool, gameId);

  const result: CatalogResult = { pages: 0, cards: 0, editions: 0, seededFinishes: 0 };
  // Sets repeat across nearly every page; cache so we upsert each one once.
  const setIds = new Map<string, string>();

  try {
    for await (const page of client.allPages()) {
      result.pages++;

      for (const card of page.data) {
        const cardId = await db.upsertCard(pool, gameId, card);
        result.cards++;

        for (const edition of card.editions ?? []) {
          if (!edition.set) {
            log(`  skip edition ${edition.uuid}: no set`);
            continue;
          }

          let setId = setIds.get(edition.set.id);
          if (!setId) {
            setId = await db.upsertSet(pool, gameId, edition.set);
            setIds.set(edition.set.id, setId);
          }

          const editionId = await db.upsertEdition(pool, cardId, setId, edition);
          const finishes = resolveFinishes(edition);
          await db.upsertFinishes(pool, editionId, finishes);

          result.editions++;
          if (finishes[0]?.isSeeded) result.seededFinishes += finishes.length;
        }
      }

      log(
        `page ${String(page.page).padStart(2)} ` +
          `| +${page.data.length} cards ` +
          `| running totals ${result.cards} cards / ${result.editions} editions`,
      );
    }

    await db.finishSyncRun(pool, runId, 'succeeded', {
      pages: result.pages,
      cards: result.cards,
      editions: result.editions,
      images: 0,
    });
    return result;
  } catch (err) {
    await db.finishSyncRun(
      pool,
      runId,
      'failed',
      { pages: result.pages, cards: result.cards, editions: result.editions, images: 0 },
      err instanceof Error ? err.message : String(err),
    );
    throw err;
  }
}
