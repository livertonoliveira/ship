'use strict';

// Unified ceiling: every compiled SKILL.md and every compiled agent .md must
// stay under 1000 words, with a narrow, evidence-based exception for the
// true multi-phase orchestrators (see BUDGETS.md "Orchestrator tier").
const DEFAULT_BUDGET = 999;
const ORCHESTRATOR_TIER_BUDGET = 1200;

const WORD_BUDGETS = {
  run: ORCHESTRATOR_TIER_BUDGET,
  homolog: ORCHESTRATOR_TIER_BUDGET,
};

module.exports = { WORD_BUDGETS, DEFAULT_BUDGET };
