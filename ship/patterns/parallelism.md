# Parallelism Strategy

- Use the **Agent** tool to launch N agents in parallel in a **SINGLE call**
- Never execute sequentially what can be parallel
- Each parallel agent writes to separate files to avoid race conditions
- When classifying workspaces (monorepo): cross-reference the diff/source tree with workspaces in `ship/config.md`, launch one agent per affected workspace
