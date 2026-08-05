/**
 * A deliberately slow HTTP client.
 *
 * We are a guest on someone else's free API. Two independent throttles:
 *
 *   - a concurrency gate, so we never have more than N requests in flight
 *   - a global minimum interval, so even at concurrency 1 we space requests out
 *
 * Plus retries with exponential backoff and jitter on the failures that are
 * worth retrying (429, 5xx, network faults), and never on the ones that are
 * not (404, 400) -- retrying those just wastes their capacity and our time.
 */

export class RequestFailed extends Error {
  constructor(
    readonly url: string,
    readonly status: number | null,
    message: string,
  ) {
    super(message);
    this.name = 'RequestFailed';
  }
}

const RETRYABLE_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);

export interface PoliteClientOptions {
  minIntervalMs: number;
  concurrency: number;
  maxRetries: number;
  userAgent: string;
}

export class PoliteClient {
  #inFlight = 0;
  #queue: Array<() => void> = [];
  #nextSlotAt = 0;
  #aborted = false;

  constructor(private readonly opts: PoliteClientOptions) {}

  /** Stop admitting new requests. In-flight ones are left to finish. */
  abort(): void {
    this.#aborted = true;
  }

  get aborted(): boolean {
    return this.#aborted;
  }

  async fetch(url: string, init: RequestInit = {}): Promise<Response> {
    await this.#acquire();
    try {
      return await this.#withRetries(url, init);
    } finally {
      this.#release();
    }
  }

  /** Fetch and parse JSON, failing loudly on a non-2xx. */
  async json<T>(url: string): Promise<T> {
    const res = await this.fetch(url, { headers: { accept: 'application/json' } });
    if (!res.ok) throw new RequestFailed(url, res.status, `HTTP ${res.status}`);
    return (await res.json()) as T;
  }

  async #withRetries(url: string, init: RequestInit): Promise<Response> {
    let lastError: unknown;

    for (let attempt = 0; attempt <= this.opts.maxRetries; attempt++) {
      if (attempt > 0) await sleep(this.#backoffMs(attempt, lastError));
      await this.#waitForSlot();

      try {
        const res = await fetch(url, {
          ...init,
          headers: { 'user-agent': this.opts.userAgent, ...(init.headers ?? {}) },
        });

        // 304 is a success for our purposes: the cached copy is still good.
        if (res.ok || res.status === 304) return res;

        if (!RETRYABLE_STATUS.has(res.status)) {
          throw new RequestFailed(url, res.status, `HTTP ${res.status} (not retryable)`);
        }
        lastError = res;
      } catch (err) {
        if (err instanceof RequestFailed) throw err; // non-retryable, already decided
        lastError = err;
      }
    }

    const status = lastError instanceof Response ? lastError.status : null;
    throw new RequestFailed(url, status, `gave up after ${this.opts.maxRetries} retries`);
  }

  /** Honour Retry-After when the server sends one; otherwise exponential + jitter. */
  #backoffMs(attempt: number, lastError: unknown): number {
    if (lastError instanceof Response) {
      const header = lastError.headers.get('retry-after');
      if (header) {
        const seconds = Number.parseInt(header, 10);
        if (Number.isFinite(seconds)) return Math.min(seconds * 1000, 60_000);
      }
    }
    const base = Math.min(1000 * 2 ** (attempt - 1), 30_000);
    return base + Math.random() * 250;
  }

  /** Space requests out globally, independent of concurrency. */
  async #waitForSlot(): Promise<void> {
    const now = Date.now();
    const wait = Math.max(0, this.#nextSlotAt - now);
    this.#nextSlotAt = Math.max(now, this.#nextSlotAt) + this.opts.minIntervalMs;
    if (wait > 0) await sleep(wait);
  }

  async #acquire(): Promise<void> {
    if (this.#inFlight < this.opts.concurrency) {
      this.#inFlight++;
      return;
    }
    await new Promise<void>((resolve) => this.#queue.push(resolve));
    this.#inFlight++;
  }

  #release(): void {
    this.#inFlight--;
    this.#queue.shift()?.();
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
