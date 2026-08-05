/**
 * Phase 2: copy card images into our own storage.
 *
 * The slow half -- 4,504 images, ~0.76 GB at a 165 KB mean. Two properties
 * matter more than speed:
 *
 *   - polite: bounded concurrency and a spacing interval, so we never hammer
 *     a free API that owes us nothing
 *   - resumable: a card_image row is the checkpoint, so an interrupted or
 *     deliberately capped run just continues next time. Nothing to time out.
 */

import { config } from './config.js';
import * as db from './db.js';
import { GatcgClient } from './gatcg.js';
import type { PoliteClient } from './http.js';
import { createStorage, imageKey, jpegSize, sha256 } from './storage.js';

export interface ImageResult {
  attempted: number;
  stored: number;
  failed: number;
  bytes: number;
  remaining: number;
}

export async function backfillImages(
  pool: db.Db,
  http: PoliteClient,
  log: (msg: string) => void,
  opts: { variant?: string; limit?: number | null } = {},
): Promise<ImageResult> {
  const variant = opts.variant ?? 'original';
  const limit = opts.limit ?? null;

  const client = new GatcgClient(http);
  const storage = createStorage();
  const pending = await db.pendingImages(pool, variant, limit);

  const result: ImageResult = { attempted: 0, stored: 0, failed: 0, bytes: 0, remaining: 0 };
  if (pending.length === 0) {
    log('nothing to fetch -- every edition already has a stored image');
    return result;
  }

  log(`${pending.length} images to fetch -> ${storage.name} storage (concurrency ${config.gatcg.imageConcurrency})`);

  // A simple index-sharing worker pool: N workers pull from one cursor, so a
  // slow download never blocks the others.
  let cursor = 0;
  // Workers check progress after their own await, so several can observe the
  // same count and each print it. Track what was last printed instead.
  let lastReported = 0;
  const startedAt = Date.now();

  const worker = async (): Promise<void> => {
    while (true) {
      if (http.aborted) return;
      const index = cursor++;
      const item = pending[index];
      if (!item) return;

      result.attempted++;
      const url = client.imageUrl(item.sourcePath);

      try {
        const res = await http.fetch(url);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);

        const body = new Uint8Array(await res.arrayBuffer());
        const contentType = res.headers.get('content-type') ?? 'image/jpeg';
        const key = imageKey(item.externalUuid, variant);
        const dims = jpegSize(body);

        await storage.put(key, body, contentType);
        await db.recordImage(pool, {
          editionId: item.editionId,
          variant,
          storageKey: key,
          contentType,
          byteSize: body.byteLength,
          width: dims?.width ?? null,
          height: dims?.height ?? null,
          sourceUrl: url,
          checksum: sha256(body),
        });

        result.stored++;
        result.bytes += body.byteLength;
      } catch (err) {
        // Left unrecorded on purpose: no card_image row means the next run
        // retries it. Failures are self-healing rather than sticky.
        result.failed++;
        log(`  FAILED ${item.externalUuid}: ${err instanceof Error ? err.message : String(err)}`);
      }

      const done = result.attempted;
      if (done > lastReported && (done % 100 === 0 || done === pending.length)) {
        lastReported = done;
        const elapsed = (Date.now() - startedAt) / 1000;
        const rate = done / Math.max(elapsed, 0.001);
        const left = pending.length - done;
        log(
          `  ${done}/${pending.length} ` +
            `| ${(result.bytes / 1e6).toFixed(0)} MB ` +
            `| ${rate.toFixed(1)}/s ` +
            `| ~${Math.round(left / Math.max(rate, 0.001) / 60)} min left` +
            (result.failed ? ` | ${result.failed} failed` : ''),
        );
      }
    }
  };

  await Promise.all(
    Array.from({ length: Math.max(1, config.gatcg.imageConcurrency) }, () => worker()),
  );

  result.remaining = (await db.pendingImages(pool, variant, null)).length;
  return result;
}
