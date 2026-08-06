-- A handful of placeholder cards, so the app can be tried before the real
-- catalog import has run.
--
-- Paste into the Supabase SQL editor. Safe to run more than once.
--
-- THIS IS NOT THE CATALOG. These rows are invented scaffolding with a
-- deliberately obvious set name, so nothing here is mistaken for real Grand
-- Archive data. The actual catalog comes from api.gatcg.com via the Ingest
-- catalog workflow (16, 12), and these rows do not become part of it.
--
-- Remove them when the real catalog lands -- see the bottom of this file.

INSERT INTO game (id, slug, name)
VALUES ('00000000-0000-4000-a000-000000000001', 'grand-archive', 'Grand Archive')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO card_set (id, game_id, external_id, prefix, name)
VALUES ('00000000-0000-4000-a000-000000000002',
        (SELECT id FROM game WHERE slug = 'grand-archive'),
        'sample-set', 'SAMPLE', 'Sample Set (placeholder data)')
ON CONFLICT (game_id, external_id) DO NOTHING;

-- Names are plainly fictional. Real card names would make these rows hard to
-- tell apart from imported ones.
INSERT INTO card (id, game_id, external_uuid, slug, name)
VALUES
  ('00000000-0000-4000-a000-000000000011',
   (SELECT id FROM game WHERE slug = 'grand-archive'),
   'sample-card-1', 'sample-ember-adept', 'Sample Ember Adept'),
  ('00000000-0000-4000-a000-000000000012',
   (SELECT id FROM game WHERE slug = 'grand-archive'),
   'sample-card-2', 'sample-tidecaller', 'Sample Tidecaller'),
  ('00000000-0000-4000-a000-000000000013',
   (SELECT id FROM game WHERE slug = 'grand-archive'),
   'sample-card-3', 'sample-stone-sentinel', 'Sample Stone Sentinel'),
  ('00000000-0000-4000-a000-000000000014',
   (SELECT id FROM game WHERE slug = 'grand-archive'),
   'sample-card-4', 'sample-windrunner', 'Sample Windrunner')
ON CONFLICT (game_id, external_uuid) DO NOTHING;

INSERT INTO card_edition (id, card_id, set_id, external_uuid, slug, collector_number)
VALUES
  ('00000000-0000-4000-a000-000000000021', '00000000-0000-4000-a000-000000000011',
   '00000000-0000-4000-a000-000000000002', 'sample-ed-1', 'sample-ember-adept-1', '001'),
  ('00000000-0000-4000-a000-000000000022', '00000000-0000-4000-a000-000000000012',
   '00000000-0000-4000-a000-000000000002', 'sample-ed-2', 'sample-tidecaller-1', '002'),
  ('00000000-0000-4000-a000-000000000023', '00000000-0000-4000-a000-000000000013',
   '00000000-0000-4000-a000-000000000002', 'sample-ed-3', 'sample-stone-sentinel-1', '003'),
  ('00000000-0000-4000-a000-000000000024', '00000000-0000-4000-a000-000000000014',
   '00000000-0000-4000-a000-000000000002', 'sample-ed-4', 'sample-windrunner-1', '004')
ON CONFLICT (external_uuid) DO NOTHING;

-- Deliberately mixed, so the finish dropdown can be seen doing its job (21):
-- the Stone Sentinel exists only in foil and must not offer nonfoil.
INSERT INTO card_edition_finish (edition_id, finish) VALUES
  ('00000000-0000-4000-a000-000000000021', 'NONFOIL'),
  ('00000000-0000-4000-a000-000000000021', 'FOIL'),
  ('00000000-0000-4000-a000-000000000022', 'NONFOIL'),
  ('00000000-0000-4000-a000-000000000023', 'FOIL'),
  ('00000000-0000-4000-a000-000000000024', 'NONFOIL')
ON CONFLICT DO NOTHING;

SELECT c.name AS card, s.name AS set, e.collector_number AS num,
       string_agg(f.finish::text, ', ' ORDER BY f.finish) AS finishes
  FROM card_edition e
  JOIN card c        ON c.id = e.card_id
  JOIN card_set s    ON s.id = e.set_id
  LEFT JOIN card_edition_finish f ON f.edition_id = e.id
 WHERE s.external_id = 'sample-set'
 GROUP BY c.name, s.name, e.collector_number
 ORDER BY e.collector_number;

-- ---------------------------------------------------------------------------
-- Removing these afterwards
-- ---------------------------------------------------------------------------
--
-- Run this once the real catalog is imported. It will REFUSE if you own any
-- copies of a sample card -- card_edition is ON DELETE RESTRICT from holding,
-- which is the schema declining to erase a record of something you own. Delete
-- those holdings first if you really mean it.
--
--   DELETE FROM card_edition_finish
--    WHERE edition_id IN (SELECT id FROM card_edition
--                          WHERE set_id = '00000000-0000-4000-a000-000000000002');
--   DELETE FROM card_edition
--    WHERE set_id = '00000000-0000-4000-a000-000000000002';
--   DELETE FROM card
--    WHERE external_uuid LIKE 'sample-card-%';
--   DELETE FROM card_set
--    WHERE id = '00000000-0000-4000-a000-000000000002';
