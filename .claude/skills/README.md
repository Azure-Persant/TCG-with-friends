# Skills

Matt Pocock's skill set, from https://github.com/mattpocock/skills
(MIT). Installed as **editable copies** rather than the managed plugin, so
they can be adapted to this project — the tradeoff is that upstream fixes do
not arrive on their own.

To take the managed version instead, run `/plugin install mattpocock-skills`
and delete this directory. Do not do both: you would get every skill twice.

## The ones this project has leant on

| Skill | What it does |
|---|---|
| `grilling` | Interview until the design tree has no unvisited branches. Rounds of questions, each round the frontier of decisions whose prerequisites are settled. |
| `grill-me` | User-invoked wrapper around `grilling`. |
| `to-tickets` | Break a plan into tracer-bullet tickets with explicit blocking edges, then publish them. |
| `setup-matt-pocock-skills` | Configures the tracker and label vocabulary the engineering skills expect. **Not yet run here** — see below. |

## Not yet configured

`setup-matt-pocock-skills` has not been run against this repo, so:

- No triage label vocabulary exists. Issues #10–#16 were published without the
  `ready-for-agent` label that `to-tickets` would normally apply.
- The issue tracker is GitHub by convention rather than by configuration.

Run `/setup-matt-pocock-skills` to settle both.
