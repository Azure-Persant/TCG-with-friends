export type FilterOption = { kind: string; value: string; count: number }

export type FilterValues = {
  q: string
  elements: string[]
  types: string[]
  subtypes: string[]
  classes: string[]
  memMin: string
  memMax: string
  resMin: string
  resMax: string
}

/**
 * Same query-string shape / semantics as the retired Softgen prototype's
 * filter bar (issue #20): OR within a control (checking two elements matches
 * either), AND across controls. A plain GET form -- server-rendered, no
 * client JS required, one round trip per change -- rather than a fetch-driven
 * combobox, since search_card_editions already does the real work in
 * Postgres and this just needs to shape the query string for it.
 */
export function readFilterValues(sp: Record<string, string | string[] | undefined>): FilterValues {
  const list = (v: string | string[] | undefined) => (Array.isArray(v) ? v : v ? [v] : [])
  return {
    q: typeof sp.q === 'string' ? sp.q : '',
    elements: list(sp.el),
    types: list(sp.ty),
    subtypes: list(sp.st),
    classes: list(sp.cl),
    memMin: typeof sp.memMin === 'string' ? sp.memMin : '',
    memMax: typeof sp.memMax === 'string' ? sp.memMax : '',
    resMin: typeof sp.resMin === 'string' ? sp.resMin : '',
    resMax: typeof sp.resMax === 'string' ? sp.resMax : '',
  }
}

export function hasAnyFilter(v: FilterValues): boolean {
  return (
    v.q.trim() !== '' ||
    v.elements.length > 0 ||
    v.types.length > 0 ||
    v.subtypes.length > 0 ||
    v.classes.length > 0 ||
    v.memMin !== '' ||
    v.memMax !== '' ||
    v.resMin !== '' ||
    v.resMax !== ''
  )
}

export function FilterBar({
  values,
  options,
}: {
  values: FilterValues
  options: FilterOption[]
}) {
  const byKind = (kind: string) => options.filter((o) => o.kind === kind)

  return (
    <form method="get" className="flex flex-col gap-3">
      <div className="flex gap-2">
        <input
          name="q"
          defaultValue={values.q}
          placeholder="Search for a card…"
          aria-label="Card name"
          className="flex-1 rounded-md border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent"
        />
        <button
          type="submit"
          className="rounded-md bg-accent px-4 py-2 text-sm font-medium text-white transition hover:opacity-90"
        >
          Search
        </button>
      </div>

      <div className="flex flex-wrap gap-3">
        <CheckboxGroup label="Element" name="el" selected={values.elements} options={byKind('element')} />
        <CheckboxGroup label="Type" name="ty" selected={values.types} options={byKind('type')} />
        <CheckboxGroup label="Subtype" name="st" selected={values.subtypes} options={byKind('subtype')} />
        <CheckboxGroup label="Class" name="cl" selected={values.classes} options={byKind('class')} />

        <details className="rounded-md border border-slate-700">
          <summary className="cursor-pointer px-3 py-1.5 text-sm font-medium">Cost</summary>
          <div className="flex flex-col gap-2 border-t border-white/10 p-3 text-sm">
            <CostRange label="Memory" minName="memMin" maxName="memMax" min={values.memMin} max={values.memMax} />
            <CostRange label="Reserve" minName="resMin" maxName="resMax" min={values.resMin} max={values.resMax} />
          </div>
        </details>
      </div>
    </form>
  )
}

function CheckboxGroup({
  label,
  name,
  selected,
  options,
}: {
  label: string
  name: string
  selected: string[]
  options: FilterOption[]
}) {
  if (options.length === 0) return null

  return (
    <details className="rounded-md border border-slate-700" open={selected.length > 0}>
      <summary className="cursor-pointer px-3 py-1.5 text-sm font-medium">
        {label}
        {selected.length > 0 && <span className="ml-1 text-accent">({selected.length})</span>}
      </summary>
      <div className="flex max-h-56 flex-col gap-1 overflow-y-auto border-t border-white/10 p-3 text-sm">
        {options.map((o) => (
          <label key={o.value} className="flex items-center gap-2">
            <input
              type="checkbox"
              name={name}
              value={o.value}
              defaultChecked={selected.includes(o.value)}
              className="accent-current text-accent"
            />
            {o.value}
            <span className="text-xs text-slate-400">({o.count})</span>
          </label>
        ))}
      </div>
    </details>
  )
}

function CostRange({
  label,
  minName,
  maxName,
  min,
  max,
}: {
  label: string
  minName: string
  maxName: string
  min: string
  max: string
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="w-16 text-slate-400">{label}</span>
      <input
        type="number"
        name={minName}
        defaultValue={min}
        placeholder="min"
        min={0}
        className="w-16 rounded-md border border-slate-700 bg-slate-800 px-2 py-1 text-slate-100"
      />
      <span className="text-slate-400">–</span>
      <input
        type="number"
        name={maxName}
        defaultValue={max}
        placeholder="max"
        min={0}
        className="w-16 rounded-md border border-slate-700 bg-slate-800 px-2 py-1 text-slate-100"
      />
    </div>
  )
}
