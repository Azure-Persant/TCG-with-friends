/**
 * Ingest CLI.
 *
 *   npm run catalog                 crawl card/edition JSON (fast)
 *   npm run images                  backfill card images (slow, resumable)
 *   npm run images -- --limit 500   fetch only the next 500
 *   npm run all                     catalog, then images
 *
 * Ctrl-C is a clean stop: in-flight work finishes, nothing is corrupted, and
 * the next run resumes from where this one left off.
 */

import { config } from './config.js';
import { ingestCatalog } from './catalog.js';
import { connect } from './db.js';
import { PoliteClient } from './http.js';
import { backfillImages } from './images.js';

function log(msg: string): void {
  const stamp = new Date().toISOString().slice(11, 19);
  console.log(`[${stamp}] ${msg}`);
}

interface Args {
  command: 'catalog' | 'images' | 'all';
  limit: number | null;
  variant: string;
}

function parseArgs(argv: string[]): Args {
  const [command = 'all'] = argv;
  if (command !== 'catalog' && command !== 'images' && command !== 'all') {
    throw new Error(`Unknown command "${command}". Expected catalog | images | all.`);
  }

  let limit: number | null = null;
  let variant = 'original';

  for (let i = 1; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--limit') {
      const raw = argv[++i];
      const n = Number.parseInt(raw ?? '', 10);
      if (!Number.isFinite(n) || n <= 0) throw new Error('--limit needs a positive integer');
      limit = n;
    } else if (arg === '--variant') {
      const raw = argv[++i];
      if (!raw) throw new Error('--variant needs a value');
      variant = raw;
    } else {
      throw new Error(`Unknown flag "${arg}"`);
    }
  }

  return { command, limit, variant };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  const http = new PoliteClient({
    minIntervalMs: config.gatcg.minIntervalMs,
    concurrency: args.command === 'catalog' ? 1 : config.gatcg.imageConcurrency,
    maxRetries: config.gatcg.maxRetries,
    userAgent: config.gatcg.userAgent,
  });

  let stopping = false;
  const onSignal = (): void => {
    if (stopping) process.exit(130);
    stopping = true;
    log('stop requested -- finishing in-flight work, then exiting. Re-run to resume.');
    http.abort();
  };
  process.on('SIGINT', onSignal);
  process.on('SIGTERM', onSignal);

  const pool = connect();
  const startedAt = Date.now();

  try {
    if (args.command === 'catalog' || args.command === 'all') {
      log(`crawling ${config.gatcg.baseUrl} (page size ${config.gatcg.pageSize}, ${config.gatcg.minIntervalMs}ms spacing)`);
      const r = await ingestCatalog(pool, http, log);
      log(
        `catalog done: ${r.pages} pages, ${r.cards} cards, ${r.editions} editions, ` +
          `${r.seededFinishes} seeded finish rows`,
      );
    }

    if (args.command === 'images' || args.command === 'all') {
      const r = await backfillImages(pool, http, log, { variant: args.variant, limit: args.limit });
      log(
        `images done: ${r.stored} stored, ${r.failed} failed, ` +
          `${(r.bytes / 1e6).toFixed(0)} MB, ${r.remaining} still pending`,
      );
      if (r.remaining > 0) log('re-run `npm run images` to continue -- it picks up where this stopped');
    }

    log(`finished in ${((Date.now() - startedAt) / 1000).toFixed(1)}s`);
  } finally {
    await pool.end();
  }
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.stack ?? err.message : err);
  process.exit(1);
});
