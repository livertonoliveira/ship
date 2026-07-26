'use strict';

// Per-file ceiling for every compiled SKILL.md and agent .md.
//
// Raised from 999 to 1500 after the distribution showed the old ceiling was
// shaping content rather than bounding it: 16 of 29 files sat within 100 words
// of it and 10 of 11 agents did, which is the signature of files compressed to
// fit rather than files that naturally stay small. The concrete cost was
// observed — a `ship/config.md` path was dropped from spec/SKILL.md purely to
// buy room, exactly the degradation this file warns about.
//
// The ceiling was never the real defence anyway. The Anti-Bloat Rule is: move
// the logic to a script or remove the surface. Prose can fit under any ceiling
// and still be the wrong fix.
const DEFAULT_BUDGET = 1500;

// Empty on purpose: with a 1500 default, the old 1200 orchestrator tier for
// `run` and `homolog` is no longer an exception to anything.
const WORD_BUDGETS = {};

// Aggregate ceilings. These are what actually bound context cost — the per-file
// ceiling only bounds one file at a time, and a fleet of files each just under
// it adds up to the same bloat the per-file number was meant to prevent.
//
// Each budget sits BELOW the sum of its group's per-file ceilings, or it would
// constrain nothing. Sized at roughly current + 40%: room for real growth,
// tight enough that drift across the whole group trips it.
const FOOTPRINT_BUDGETS = {
  // The files a typical /ship:run pulls in. 10 files × 1500 = 15000 possible.
  run: 12000,
  // Spec-time surface, previously covered by no aggregate at all.
  // 3 files × 1500 = 4500 possible.
  spec: 3800,
  // Every audit skill and its worker. 11 files × 1500 = 16500 possible.
  audit: 12000,
};

// Kept for the CI step and tests that reference it by name.
const RUN_FOOTPRINT_BUDGET = FOOTPRINT_BUDGETS.run;

module.exports = { WORD_BUDGETS, DEFAULT_BUDGET, FOOTPRINT_BUDGETS, RUN_FOOTPRINT_BUDGET };
