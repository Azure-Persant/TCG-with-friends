/** Environment-driven configuration. Loaded once at startup. */

function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) throw new Error(`Missing required env var ${name}`);
  return v;
}

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
  return n;
}

export const config = {
  databaseUrl: env('DATABASE_URL'),

  gatcg: {
    /** Verified: the API silently caps page_size at 50, so asking for more is wasted. */
    baseUrl: env('GATCG_BASE_URL', 'https://api.gatcg.com'),
    pageSize: 50,
    minIntervalMs: intEnv('GATCG_MIN_INTERVAL_MS', 250),
    imageConcurrency: intEnv('GATCG_IMAGE_CONCURRENCY', 4),
    maxRetries: intEnv('GATCG_MAX_RETRIES', 5),
    userAgent: env(
      'GATCG_USER_AGENT',
      'friends-card-inventory-ingest/0.1 (+https://github.com/JonCorrea/friends-card-inventory)',
    ),
  },

  storage: {
    driver: env('STORAGE_DRIVER', 'local') as 'local' | 'supabase',
    localDir: env('STORAGE_LOCAL_DIR', './.storage'),
    supabaseUrl: process.env['SUPABASE_URL'] ?? '',
    supabaseKey: process.env['SUPABASE_SERVICE_ROLE_KEY'] ?? '',
    bucket: env('SUPABASE_STORAGE_BUCKET', 'card-images'),
  },

  /** The one game this worker knows how to ingest. */
  game: { slug: 'grand-archive', name: 'Grand Archive' },
} as const;
