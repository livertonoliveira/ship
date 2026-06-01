# Linear Status — resolve, set, and verify workflow-state transitions

> Canonical recipe for moving a task issue between workflow states.
> Used by `ship:run` / `ship:develop` (→ started) and `ship:homolog` / `ship:run` (→ completed).

A workflow-state **name** is team-configurable, so passing a hardcoded literal like `"In Progress"`
or `"Done"` to `save_issue` is unsafe: the `state` parameter is matched by state **name, type, or
ID**, and a team may have renamed it (e.g., `Em andamento`, `Concluído`, `Shipped`). When the name
does not match, the transition silently no-ops and the issue is left in its previous state.

Likewise, `get_issue_status` does **not** read an issue's current state — it requires
`id` + `name` + `team` and returns the definition of a status entity. To read the state an issue is
currently in, use `get_issue` and inspect its `state` field.

Linear workflow states each have a stable `type`. The two the pipeline transitions to are:

| Transition | Linear state `type` | Config field captured at `ship:init` | Default name |
|------------|---------------------|--------------------------------------|--------------|
| Start work | `started`           | `In Progress Status`                 | `In Progress` |
| Complete   | `completed`         | `Done Status`                        | `Done` |

---

## 1. Resolve the target state (do this once per transition)

1. Read the relevant config field (`In Progress Status` or `Done Status`) and `Team ID` from
   `ship/config.md → Linear Integration`.
2. If the field is present and not `not configured`, use it as the target state — it stores the
   team's real state name captured at `ship:init`.
3. If it is **absent** (older config) or `not configured`: call
   `mcp__linear-server__list_issue_statuses` with the `Team ID`, select the state whose `type`
   matches the transition (`started` or `completed`), and use its **name** as the target. If more
   than one state of that type exists, prefer the conventional name (`In Progress`/`Em andamento`
   for started; `Done`/`Concluído` for completed); otherwise take the first.

Call the resolved value `<target-state>`.

## 2. Set the state

Call `mcp__linear-server__save_issue` with:
- `id`: the task issue identifier (e.g., `MOB-1147`)
- `state`: `<target-state>`

## 3. Verify (never use `get_issue_status` for this)

Call `mcp__linear-server__get_issue` for the task issue and read its `state` field.
The transition succeeded when `state.type` matches the intended type (`started` or `completed`) —
a name-agnostic check.

If it does not match, the set failed — re-resolve `<target-state>` per step 1 (the configured name
may be stale), call `save_issue` again, and re-verify **once**. If it still fails, surface the issue
to the user with the resolved state name so they can fix the mapping in `ship/config.md` — do not
loop indefinitely.
