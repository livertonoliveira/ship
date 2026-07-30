---
name: ship:graph
description: "Runs a feature's independent tasks in parallel: one isolated workspace per task, dependency and file-conflict edges, a merge node that verifies them together."
argument-hint: "<linear-project-url | project-name | local-feature-dir> [--driver manual|local|orca] [--max-in-flight N] [--repo <id>]"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Graph — Cross-Task Parallelism

Admission, conflict edges, the merge node and every gate live in one deterministic state machine: `graph.sh next`. You are its executor — call it, do exactly what it prints, call it again. You never decide which task runs next.

Each node is a full `/ship:run` in its own workspace. Nothing inside a task changes: develop stays sequential, verify stays a fan-out, gates and the fix-loop cap stay intact.

**Input received:** $ARGUMENTS

> **STRICT RULE:** never run `ship:audit:*` from here — audits are project-wide and user-triggered.

> `${CLAUDE_SKILL_DIR}/...` failure: log, skip — never search the filesystem.

## Prerequisites

`ship/config.md` must exist (else `/ship:init` + STOP); storage mode ${CLAUDE_SKILL_DIR}/patterns/storage-mode.md. Omit `--driver` unless the user named one: `init` probes each driver and takes the keenest that reports ready, echoing `driver=` and `driver_chosen_by=`. Never pick one yourself.

## 1. Resolve the project

The input is a whole feature, never a single issue — a graph of one node is just `/ship:run`. Resolve it to a project and to a feature name, in this order:

- `linear.app/**/project/**` URL → `list_projects` / `get_project` and take the project's **name**. Never derive the feature from the URL itself: its trailing id makes two copy-pastes of the same project look like two features.
- Bare text → the project name (Linear) or the `ship/changes/<dir>` folder (local).

Pass that name to `init` as-is — `graph.sh` slugifies it (`Autenticação V2` → `autenticacao-v2`) and echoes back `feature=<slug>`, which is the graph's identity from then on.

## 2. Build `nodes.json` — yourself, no sub-agent

This is the only judgment step. One JSON array; each object is `{ "id", "repo", "title", "deps": [...], "files": [...] }`. `deps` are blocking task IDs, `files` the declared `## Files` paths (the footprint the conflict edge starts from).

- **Linear:** `list_issues` for that project, then `get_issue` per task. `id` = issue identifier, `deps` = the `## Deps` block plus any native **blocked by** relation, `files` = `## Files` paths, `repo` = the `repo:<name>` label if present.
- **Local:** `bash "${CLAUDE_SKILL_DIR}/hooks/graph.sh" nodes --from-tasks ship/changes/<feature>/tasks.md > nodes.json` — deterministic, no reading required.

## 3. Initialize

`bash "${CLAUDE_SKILL_DIR}/hooks/graph.sh" init --feature "<project name>" --from nodes.json --driver <d> --max-in-flight <N> --mode <linear|local> [--repo <id>]`

Pass `--repo` when the caller gave one, or when the driver needs a repo the coordinator's own directory cannot imply. Nodes without their own `repo` fall back to it.

Exit 3 with a `RESUME` report means a graph for this feature is already live — go straight to the loop; the run continues where it stopped. `--fresh` is the opposite: it discards that graph along with its in-flight claims and merge-fix counters, so pass it only when the user explicitly asks to start over.

Changing the driver or the slot count on a live graph is `bash "${CLAUDE_SKILL_DIR}/hooks/graph.sh" set [--driver <d>] [--max-in-flight N]` — never a re-init, and never `--fresh`. A driver that turns out not to work here is found only after init, and starting over is the wrong answer to it. Nodes still held by the old driver must be released first (`abort`).

Default `--max-in-flight 2`: each node is a whole pipeline (sequential develop plus a verify fan-out), so three in flight is already around a dozen concurrent agents. Raise it only when the machine has proven it can take it.

## 4. The loop

1. Run with a generous timeout (a merge node runs the whole suite inside it):
   `bash "${CLAUDE_SKILL_DIR}/hooks/graph.sh" next`
2. Parse `state=`, `action=`, `inflight=`, `frontier=`, `log=`, `instruction:` and act on the action:
   - `dispatch` → make EVERY listed call now, in this same turn, in the order printed. `dispatch` prepares the workspace, `collect` resolves its path and branch, `claim` hands both back. A driver that cannot start the worker itself returns an `instruction=` line: carrying it out is a step of the sequence, not a note — skip it and the node is claimed with a workspace nobody is working in, and the graph waits on a worker that never existed. Feed `collect`'s `worktree=`/`branch=` into `claim` verbatim.
   - `work` → run the listed command yourself, in this context.
   - `wait` → run the listed calls in order. `graph.sh poll` is what decides completion — it reads each workspace's own artifacts. Never land or fail a node from what a worker said.
   - `ask` → relay the question to the user in the artifact language, STOP; act on their answer, then go to step 1.
   - `done` → follow the closing instruction, report, STOP.
3. When every call from step 2 has returned, go to step 1. Non-zero exit: surface stderr to the user and STOP.

`bash "${CLAUDE_SKILL_DIR}/hooks/graph.sh" status` renders the graph at any point; `--json` gives the raw state. `graph-log.md` in the graph dir carries the running timeline — every claim, poll, seal and merge — and is the only progress signal visible from outside this turn.

To abandon a run, `bash "${CLAUDE_SKILL_DIR}/hooks/graph.sh" abort`: it stops each in-flight worker, marks those nodes failed and keeps their workspaces. Killing the orchestrator does NOT do this — workers survive it and keep billing.

## Rules

- Never start a task the instruction did not list, never skip one it did, never reorder — the state machine already decided. A task missing from the frontier is blocked by a dependency or a conflict edge, not forgotten.
- Never edit `nodes.tsv`, `meta.tsv` or `graph.json` by hand — they are the graph's state, and `graph.sh` is the only writer.
- `claim` writes `homolog-mode=defer` into the task's workspace, so no node stops for its own acceptance prompt. Every report is presented in one batch at `done`.
- Completion is observed, never reported: `poll` lands a node when its pipeline leaves `homolog-approved.txt` on disk, and seals the workspace into a commit (`/ship:run` writes files but never commits, so the merge would otherwise be empty). A node whose phases stop advancing surfaces as `ask` instead of being waited on forever.
- A red merge node is the graph's own gate: it gets at most 2 fix rounds, then asks. Never merge past it by hand.
- One issue, one PR: each node opens its own, against the graph's base branch, from inside its workspace — `pipeline.sh next` emits that step itself on a green gate, and a red gate stops the node before it. The merge node then merges it by publishing the verified base. Never open or merge one by hand; `--node-pr off` turns the whole behaviour off. The final base→default-branch PR is still the user's `/ship:pr`.
- Language: user-facing output in the config's `Artifact language`; code, commits, branch names stay English (${CLAUDE_SKILL_DIR}/patterns/language.md).
