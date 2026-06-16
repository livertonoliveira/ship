# Pipeline rationale (maintainer notes)

Rationale extracted from `src/skills/run/SKILL.md` and `src/skills/spec/SKILL.md` to keep
the skill prompts lean. These notes are **not** shipped or referenced at runtime — they exist
for maintainers who need the *why* behind a step. The skills themselves carry only the
imperative *what* plus any behaviorally load-bearing warning.

---

## Baseline vs. authoritative diff classification (run step 0.7 / 2.5)

The diff is classified twice:

- **Baseline** (step 0.7) runs against the pre-develop `diff.md` and feeds **only** the
  planner-gate decision in step 1.9. It measures work that already existed *before* this run
  (re-runs, pre-committed work).
- **Authoritative** (step 2.5) is recomputed over the post-develop diff and overwrites
  `diff-class.txt`. It drives the Phase 4 quality gate and the perf/security/review slicing.

Step 2.5 exists because `ship:develop` integrates code into the working tree **without
committing** — a HEAD-based diff captured at init would be empty, so the quality phases would
analyze nothing. The refresh re-captures the working-tree diff against the merge-base.

The re-capture must be the exact `git diff "$BASE"` unified-diff command. Downstream consumers
(`diff-classifier.md`, perf/security/review slicing) parse `diff.md` as a literal unified diff;
a `--stat` body or three-dot range silently misclassifies (e.g. `0 logical files`). Hence the
assertion that a non-empty `diff.md` must contain a `diff --git` header.

## Develop evidence gate (run step 2.6)

`ship:develop` is a forked Sonnet orchestrator with **no Edit/Write tools** — it produces code
only by dispatching `ship-develop-implement` workers via the Agent tool. A known failure mode
is the orchestrator *narrating* the plan and returning a success-looking status without ever
dispatching a worker, leaving the working tree untouched. The gate therefore never trusts
develop's self-report: it proves, from the working-tree snapshots, that real code was produced.
The empty-diff case is disambiguated against the pre-develop baseline (legitimate re-run vs.
silent failure).

## Orchestrator is not the planner (run step 1.9)

The orchestrator must resist deep-reading the codebase or reasoning about domain semantics
before dispatching `ship:plan` — that analysis is the planner's job; duplicating it wastes
tokens and produces unverified hypotheses the planner may contradict. The only pre-plan
judgment the orchestrator makes is the deterministic baseline classification (step 0.7) that
decides *whether* to run the planner.

## Spec: execution modes and decomposition philosophy

`ship:spec` is standalone (does not require `/ship:run`) but is also callable from the pipeline.
Task decomposition targets <400 lines of change per task so each task fits a single develop
fan-out and stays reviewable. Scenarios are enumerated at spec time (full Gherkin `@SC-XX`)
so develop and test derive code and tests from one interpretation — see the Gherkin-at-spec-time
decision in project memory.
