/**
 * Print what is actually in the catalog. Run after an ingest so the job
 * summary answers "did that work?" without opening the database.
 */
import pg from 'pg'

const client = new pg.Client({
  connectionString: process.env.DATABASE_URL,
  ssl: /supabase\.(co|com|net)/.test(process.env.DATABASE_URL ?? '')
    ? { rejectUnauthorized: false }
    : undefined,
})

try {
  await client.connect()
  const { rows } = await client.query(`
    SELECT (SELECT count(*) FROM card_set)     AS sets,
           (SELECT count(*) FROM card)         AS cards,
           (SELECT count(*) FROM card_edition) AS editions,
           (SELECT count(*) FROM card_image)   AS images`)

  const r = rows[0]
  console.log('\nCatalog now holds:')
  console.log(`  sets      ${r.sets}`)
  console.log(`  cards     ${r.cards}`)
  console.log(`  editions  ${r.editions}`)
  console.log(`  images    ${r.images}`)

  if (Number(r.cards) === 0) {
    console.log('\nNo cards. The run did not import anything — check the log above.')
  }
} catch (err) {
  console.error(`Could not read the catalog: ${err.message}`)
} finally {
  await client.end().catch(() => {})
}
