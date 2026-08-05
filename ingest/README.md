# Catalog ingest worker

Pulls the Grand Archive catalog from `api.gatcg.com` into our own database and
copies every card image into our own storage, so the app never contacts
gatcg.com at runtime.

Two phases, run independently:

| Phase | What it does | Cost |
|---|---|---|
| `catalog` | 45 paginated JSON requests → cards, editions, sets, finishes | ~90 seconds |
| `images` | 4,504 image downloads → object storage | ~19 minutes, 0.76 GB |

## Setup

```bash
cd ingest
npm install
cp .env.example .env      # then edit DATABASE_URL and storage settings
```

The database must already have `db/schema.sql` applied.

## Running

```bash
npm run catalog             # crawl JSON only
npm run images              # backfill every missing image
npm run images -- --limit 500   # do 500 and stop
npm run all                 # catalog, then images
```

Both phases are **idempotent** — every write is an upsert, so re-running never
duplicates anything and is the normal way to pick up a new set release.

## Resumability

The image phase has no checkpoint file and no job queue. A `card_image` row
*is* the checkpoint: the worker selects editions that don't have one yet, so an
interrupted run simply continues where it stopped.

That means all three of these are the same operation:

- Ctrl-C partway through (the worker finishes in-flight downloads, then exits)
- `--limit 500` five times over
- one uninterrupted full run

A failed download deliberately writes **no** row, so the next run retries it.
Failures are self-healing rather than sticky.

## Being a good guest

GATCG runs a free public API and owes us nothing. Two independent throttles,
both configurable in `.env`:

| Setting | Default | Effect |
|---|---|---|
| `GATCG_MIN_INTERVAL_MS` | `250` | minimum spacing between *any* two requests |
| `GATCG_IMAGE_CONCURRENCY` | `4` | max simultaneous downloads |
| `GATCG_MAX_RETRIES` | `5` | retries before giving up on one item |

That works out to roughly 4 requests/second. Retries use exponential backoff
with jitter and honour `Retry-After`. Only 429, 5xx and network faults are
retried — a 404 fails immediately rather than burning their capacity.

Please don't raise the concurrency much. The whole backfill finishing in 19
minutes instead of 5 costs us nothing and costs them a lot less.

## Upstream quirks worth knowing

- **`page_size` silently caps at 50.** Asking for 500 returns 50.
- **`total_cards` and `total_pages` are unreliable** — `total_cards` reports
  `1` when `page_size=1`. Always paginate on `has_more`.
- **No bulk endpoint.** `/bulk`, `/cards` and `/sets` all 404.
- **14.1% of editions have no circulation data** (636 of 4,504), so their
  finishes are unknown. The worker seeds both `NONFOIL` and `FOIL` for those
  and marks the rows `is_seeded = true`; otherwise a strict foreign key would
  make roughly one card in seven impossible to add to an inventory. The gaps
  cluster hard in promo and special sets — `PP1`, `P26`, `RDOA`, `ReC-AUR` and
  `PRXY` are 100% missing, `RDOPD` is 91%. Full list in
  `docs/data/editions_missing_circulation.csv`.

To find seeded rows later:

```sql
SELECT e.slug, s.prefix, f.finish
  FROM card_edition_finish f
  JOIN card_edition e ON e.id = f.edition_id
  JOIN card_set s ON s.id = e.set_id
 WHERE f.is_seeded
 ORDER BY s.prefix, e.slug;
```

## Storage drivers

`STORAGE_DRIVER=local` writes to `STORAGE_LOCAL_DIR` — the default, and what
you want for development.

`STORAGE_DRIVER=supabase` uploads to a Supabase Storage bucket using the
service-role key. Create the bucket first, and note that **0.76 GB leaves very
little room inside Supabase's 1 GB free tier** — no headroom for thumbnails.

The service-role key bypasses RLS, which is how the ingest writes catalog rows
that are read-only to everyone else. Keep it server-side; never ship it to a
browser.
