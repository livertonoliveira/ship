# Parallelism Strategy

- Use the **Agent** tool to launch N agents in parallel in a **SINGLE call**
- Never execute sequentially what can be parallel
- Each parallel agent writes to separate files to avoid race conditions
- When classifying workspaces (monorepo): cross-reference the diff/source tree with workspaces in `ship/config.md`, launch one agent per affected workspace
- **Cross-phase parallelism** (`/ship:run`): when `dev` and `test` are both enabled and `plan.md` exists, dispatch `ship:develop` and `ship:test Mode: generate` via the **Skill tool** in the same assistant turn — unlike the within-phase fan-outs above (one orchestrator launching several agents), this pairs two independent forked skills. Safe because `plan.md`'s module map and the denylist it derives for `ship:test` guarantee disjoint file sets between the two dispatches
