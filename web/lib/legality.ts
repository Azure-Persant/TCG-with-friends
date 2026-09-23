/**
 * Standard-format restricted check (39) -- same field app_set_deck_card and
 * search_card_editions read: attributes->legality->STANDARD->limit = 0.
 * Used wherever a card's `attributes` come back through an embedded
 * PostgREST select rather than through search_card_editions, which already
 * computes this server-side.
 */
export function isRestricted(attributes: Record<string, unknown> | null | undefined): boolean {
  const legality = attributes?.legality as Record<string, unknown> | undefined
  const standard = legality?.STANDARD as Record<string, unknown> | undefined
  return standard?.limit === 0
}
