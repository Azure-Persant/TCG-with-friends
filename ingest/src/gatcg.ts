/**
 * Typed client for api.gatcg.com.
 *
 * Only the fields we actually store are typed; the rest of each payload is
 * kept verbatim in the `attributes` jsonb column so a schema change upstream
 * does not silently drop data.
 */

import { config } from './config.js';
import type { PoliteClient } from './http.js';

export interface GatcgSet {
  id: string;
  name: string;
  prefix: string;
  language?: string | null;
  release_date?: string | null;
}

export interface GatcgCirculationTemplate {
  uuid?: string | null;
  kind?: 'FOIL' | 'NONFOIL' | string | null;
  foil?: boolean | null;
  name?: string | null;
  population?: number | null;
  population_operator?: string | null;
}

export interface GatcgEdition {
  uuid: string;
  slug: string;
  collector_number: string;
  rarity?: number | null;
  illustrator?: string | null;
  orientation?: string | null;
  configuration?: string | null;
  image?: string | null;
  set?: GatcgSet | null;
  circulationTemplates?: GatcgCirculationTemplate[] | null;
  [key: string]: unknown;
}

export interface GatcgCard {
  uuid: string;
  slug: string;
  name: string;
  editions?: GatcgEdition[] | null;
  [key: string]: unknown;
}

export interface GatcgSearchPage {
  data: GatcgCard[];
  has_more: boolean;
  page: number;
  page_size: number;
  /**
   * Do NOT trust these two. Verified against the live API: total_cards reports
   * 1 when page_size=1, and total_pages follows it. Paginate on has_more.
   */
  total_cards?: number;
  total_pages?: number;
}

export class GatcgClient {
  constructor(private readonly http: PoliteClient) {}

  searchPage(page: number): Promise<GatcgSearchPage> {
    const url = `${config.gatcg.baseUrl}/cards/search?page=${page}&page_size=${config.gatcg.pageSize}`;
    return this.http.json<GatcgSearchPage>(url);
  }

  /**
   * Walk every page. Yields one page at a time so the caller can write as it
   * goes rather than buffering the whole catalog in memory.
   */
  async *allPages(): AsyncGenerator<GatcgSearchPage> {
    for (let page = 1; ; page++) {
      if (this.http.aborted) return;
      const body = await this.searchPage(page);
      yield body;
      if (!body.has_more || body.data.length === 0) return;
    }
  }

  imageUrl(sourcePath: string): string {
    return `${config.gatcg.baseUrl}${sourcePath}`;
  }
}

/**
 * Which finishes a printing exists in.
 *
 * 636 of 4,504 editions (14.1%) return no circulation templates at all,
 * clustered almost entirely in promo and special sets -- PP1, P26, RDOA,
 * ReC-AUR and PRXY are 100% missing, RDOPD is 91%. Those are exactly the sets
 * where a foil-only or nonfoil-only printing is most likely, so guessing per
 * set would be wrong more often than seeding both.
 *
 * We therefore seed BOTH finishes and flag them, rather than blocking those
 * cards from being added to an inventory. See
 * docs/data/editions_missing_circulation.csv for the full list.
 */
export interface ResolvedFinish {
  finish: 'FOIL' | 'NONFOIL';
  externalUuid: string | null;
  label: string | null;
  population: number | null;
  populationOperator: string | null;
  isSeeded: boolean;
}

export function resolveFinishes(edition: GatcgEdition): ResolvedFinish[] {
  const templates = edition.circulationTemplates ?? [];
  const real = new Map<'FOIL' | 'NONFOIL', ResolvedFinish>();

  for (const t of templates) {
    // Verified 1:1 across the catalog: kind FOIL <-> foil true.
    const finish = t.kind === 'FOIL' || t.foil === true ? 'FOIL' : 'NONFOIL';
    if (real.has(finish)) continue;
    real.set(finish, {
      finish,
      externalUuid: t.uuid ?? null,
      label: t.name ?? null,
      population: t.population ?? null,
      populationOperator: t.population_operator ?? null,
      isSeeded: false,
    });
  }

  if (real.size > 0) return [...real.values()];

  return (['NONFOIL', 'FOIL'] as const).map((finish) => ({
    finish,
    externalUuid: null,
    label: null,
    population: null,
    populationOperator: null,
    isSeeded: true,
  }));
}
