'use strict';

const ORCHESTRATOR_TIER_BUDGET = 8000;
const HEAVY_TIER_BUDGET = 4000;
const PHASE_TIER_BUDGET = 3000;
const SMALL_TIER_BUDGET = 900;
const DEFAULT_BUDGET = 1000;

const WORD_BUDGETS = {
  run: ORCHESTRATOR_TIER_BUDGET,

  spec: HEAVY_TIER_BUDGET,
  pr: HEAVY_TIER_BUDGET,

  test: PHASE_TIER_BUDGET,
  develop: PHASE_TIER_BUDGET,
  plan: PHASE_TIER_BUDGET,
  homolog: PHASE_TIER_BUDGET,
  init: PHASE_TIER_BUDGET,
  'audit:run': PHASE_TIER_BUDGET,
  perf: PHASE_TIER_BUDGET,
  security: PHASE_TIER_BUDGET,
  review: PHASE_TIER_BUDGET,
  analyze: PHASE_TIER_BUDGET,

  'audit:backend': SMALL_TIER_BUDGET,
  'audit:database': SMALL_TIER_BUDGET,
  'audit:frontend': SMALL_TIER_BUDGET,
  'audit:security': SMALL_TIER_BUDGET,
  'audit:tests': SMALL_TIER_BUDGET,
};

module.exports = { WORD_BUDGETS, DEFAULT_BUDGET };
