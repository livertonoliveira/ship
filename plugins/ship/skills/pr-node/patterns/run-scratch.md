# Run Scratch — Init Artifacts

`pipeline.sh next` asks the executor to write two files into the scratch dir (`.context/ship-run/<task-id>/`) once, at init. Later phases read them instead of receiving the spec re-inlined per dispatch.

## `spec.md` — per-task slice of the spec

1. The full issue description: Context, What to do, Files section if present, Acceptance Criteria, Scenarios, Deps, Notes.
2. The full text of only the requirement sections (`REQ-XX`) from the Proposal that cover this issue's acceptance criteria.
3. A compact scope index — one line per remaining requirement in the feature not included in full:

```
- REQ-07 — Export as CSV — covered by ABC-142
```

The em-dash keeps each entry a list line rather than a section heading; the index tells later phases what is out of scope without loading its text.

## `design.md`

The full Design document, unsliced.
