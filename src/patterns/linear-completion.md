# Linear Completion — resolve, set, and verify the "Done" state

> Canonical recipe for transitioning a task issue to its completed workflow state.
> Used by `ship:homolog` (acceptance) and `ship:run` (Step 8 safety-net).

The literal string `"Done"` is **not** a safe value to pass to `save_issue`: the `state`
parameter is matched by state **name, type, or ID**, and a team's completed state may be
named differently (e.g., `Concluído`, `Completed`, `Shipped`). Hardcoding `"Done"` silently
no-ops on those teams, leaving the issue un-transitioned.

Likewise, `get_issue_status` does **not** read an issue's current state — it requires
`id` + `name` + `team` and returns the definition of a status entity. To read the state an
issue is currently in, use `get_issue` and inspect its `state` field.

---

## 1. Resolve the completed state (do this once)

1. Read `Done Status` and `Team ID` from `ship/config.md → Linear Integration`.
2. If `Done Status` is present and not `not configured`, use it as the target state
   (it stores the team's completed-state name captured at `ship:init`).
3. If it is **absent** (older config) or `not configured`: call
   `mcp__linear-server__list_issue_statuses` with the `Team ID`, select the state whose
   `type` is `completed`, and use its **name** as the target. If more than one `completed`
   state exists, prefer the one named `Done`/`Concluído`; otherwise take the first.

Call the resolved value `<completed-state>`.

## 2. Set the state

Call `mcp__linear-server__save_issue` with:
- `id`: the task issue identifier (e.g., `MOB-1147`)
- `state`: `<completed-state>`

## 3. Verify (never use `get_issue_status` for this)

Call `mcp__linear-server__get_issue` for the task issue and read its `state` field.
The transition succeeded when `state.type == "completed"` (preferred check, name-agnostic).

If `state.type != "completed"`, the set failed — re-resolve `<completed-state>` per step 1
(the configured name may be stale), call `save_issue` again, and re-verify **once**. If it
still fails, surface the issue to the user with the resolved state name so they can fix the
mapping in `ship/config.md` — do not loop indefinitely.
