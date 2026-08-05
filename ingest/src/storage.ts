/**
 * Where card images land.
 *
 * Two drivers behind one interface so the same worker fills a local directory
 * during development and a Supabase bucket in production, without the ingest
 * logic knowing which.
 */

import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { config } from './config.js';

export interface StorageDriver {
  readonly name: string;
  put(key: string, body: Uint8Array, contentType: string): Promise<void>;
}

class LocalStorage implements StorageDriver {
  readonly name = 'local';
  constructor(private readonly root: string) {}

  async put(key: string, body: Uint8Array, _contentType: string): Promise<void> {
    const path = join(resolve(this.root), key);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, body);
  }
}

class SupabaseStorage implements StorageDriver {
  readonly name = 'supabase';
  constructor(
    private readonly url: string,
    private readonly serviceRoleKey: string,
    private readonly bucket: string,
  ) {}

  async put(key: string, body: Uint8Array, contentType: string): Promise<void> {
    const endpoint = `${this.url}/storage/v1/object/${this.bucket}/${key}`;
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${this.serviceRoleKey}`,
        'content-type': contentType,
        // Re-running the ingest should overwrite rather than 409.
        'x-upsert': 'true',
      },
      body,
    });
    if (!res.ok) {
      throw new Error(`Supabase storage PUT ${key} failed: HTTP ${res.status} ${await res.text()}`);
    }
  }
}

export function createStorage(): StorageDriver {
  if (config.storage.driver === 'supabase') {
    if (!config.storage.supabaseUrl || !config.storage.supabaseKey) {
      throw new Error('STORAGE_DRIVER=supabase requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
    }
    return new SupabaseStorage(
      config.storage.supabaseUrl.replace(/\/$/, ''),
      config.storage.supabaseKey,
      config.storage.bucket,
    );
  }
  return new LocalStorage(config.storage.localDir);
}

export function sha256(body: Uint8Array): string {
  return createHash('sha256').update(body).digest('hex');
}

/**
 * Read pixel dimensions straight out of the JPEG header.
 *
 * Walks the segment markers to the start-of-frame, which carries height and
 * width. Twenty lines beats an image-processing dependency for two integers.
 */
export function jpegSize(buf: Uint8Array): { width: number; height: number } | null {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;

  let i = 2;
  while (i + 9 < buf.length) {
    if (buf[i] !== 0xff) {
      i++;
      continue;
    }
    const marker = buf[i + 1]!;
    // Standalone markers carry no length payload.
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    const length = (buf[i + 2]! << 8) | buf[i + 3]!;
    // SOF0..SOF15, excluding the DHT/JPG/DAC markers interleaved in that range.
    const isSof =
      marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      return {
        height: (buf[i + 5]! << 8) | buf[i + 6]!,
        width: (buf[i + 7]! << 8) | buf[i + 8]!,
      };
    }
    i += 2 + length;
  }
  return null;
}

/** Stable, collision-free key. The edition uuid is already unique upstream. */
export function imageKey(externalUuid: string, variant: string, ext = 'jpg'): string {
  return `${variant}/${externalUuid}.${ext}`;
}
