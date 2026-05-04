#!/bin/bash

# Ship — Development Pipeline Framework
# Installation script: copies Ship commands into your project's .claude/commands/ship/

set -e

SHIP_REPO="https://raw.githubusercontent.com/livertonoliveira/ship/main"
COMMANDS_DIR=".claude/commands/ship"
CLAUDE_MD="CLAUDE.md"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

echo ""
echo -e "${BOLD}⚒️  Ship — Development Pipeline Framework${NC}"
echo -e "${BLUE}Automated dev pipeline: intake → develop → test → perf → security → review → PR${NC}"
echo ""

# Check if we're in a project directory
if [ ! -d ".git" ] && [ ! -f "package.json" ] && [ ! -f "go.mod" ] && [ ! -f "Cargo.toml" ] && [ ! -f "pyproject.toml" ] && [ ! -f "requirements.txt" ] && [ ! -f "Gemfile" ] && [ ! -f "composer.json" ]; then
  echo -e "${YELLOW}Warning: This doesn't look like a project root directory.${NC}"
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Check if already installed
if [ -d "$COMMANDS_DIR" ]; then
  echo -e "${YELLOW}Ship is already installed in this project.${NC}"
  read -p "Overwrite existing commands? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

cleanup_harness_hooks() {
  local settings=".claude/settings.json"
  if [ ! -f "$settings" ]; then
    return 0
  fi
  if grep -q "ship hook" "$settings" 2>/dev/null; then
    if command -v jq &>/dev/null; then
      local tmp
      tmp=$(mktemp)
      if jq 'del(.hooks)' "$settings" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings"
      else
        rm -f "$tmp"
        echo "{}" > "$settings"
      fi
    else
      echo "{}" > "$settings"
    fi
    echo -e "  ${GREEN}✓${NC} Harness hooks removed from ${settings}"
  fi
}

# Cleanup harness hooks before installing
cleanup_harness_hooks

download_file() {
  local url="$1"
  local dest="$2"
  local label="$3"
  local tmp
  tmp=$(mktemp)
  local http_code
  http_code=$(curl -sL -w "%{http_code}" "$url" -o "$tmp")
  if [ "$http_code" != "200" ]; then
    echo -e "  ${RED}✗${NC} ${label} (HTTP ${http_code})"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
  echo -e "  ${GREEN}✓${NC} ${label}"
}

# Create commands directory
echo -e "${BLUE}Creating ${COMMANDS_DIR}/...${NC}"
mkdir -p "$COMMANDS_DIR"
mkdir -p "$COMMANDS_DIR/audit"

# List of command files
COMMANDS=(
  "init.md"
  "spec.md"
  "run.md"
  "develop.md"
  "test.md"
  "perf.md"
  "security.md"
  "review.md"
  "analyze.md"
  "homolog.md"
  "pr.md"
  "update.md"
)

AUDIT_COMMANDS=(
  "backend.md"
  "frontend.md"
  "database.md"
  "security.md"
  "run.md"
)

# Download commands
echo -e "${BLUE}Downloading Ship pipeline commands...${NC}"
for cmd in "${COMMANDS[@]}"; do
  skill_name="${cmd%.md}"
  download_file "${SHIP_REPO}/plugins/ship/skills/${skill_name}/SKILL.md" "${COMMANDS_DIR}/${cmd}" "${cmd}" || true
done

# Download audit commands
echo -e "${BLUE}Downloading Ship audit commands...${NC}"
for cmd in "${AUDIT_COMMANDS[@]}"; do
  skill_name="${cmd%.md}"
  download_file "${SHIP_REPO}/plugins/ship/skills/audit/${skill_name}/SKILL.md" "${COMMANDS_DIR}/audit/${cmd}" "audit/${cmd}" || true
done

# Append Ship section to CLAUDE.md if not already present
if [ -f "$CLAUDE_MD" ]; then
  if ! grep -q "Ship" "$CLAUDE_MD" 2>/dev/null; then
    echo -e "${BLUE}Adding Ship section to existing CLAUDE.md...${NC}"
    echo "" >> "$CLAUDE_MD"
    if download_file "${SHIP_REPO}/CLAUDE.ship.md" "${CLAUDE_MD}.ship.tmp" "CLAUDE.ship.md"; then
      cat "${CLAUDE_MD}.ship.tmp" >> "$CLAUDE_MD"
      rm -f "${CLAUDE_MD}.ship.tmp"
    fi
  else
    echo -e "${YELLOW}CLAUDE.md already contains Ship configuration. Skipping.${NC}"
  fi
else
  echo -e "${BLUE}Creating CLAUDE.md with Ship configuration...${NC}"
  download_file "${SHIP_REPO}/CLAUDE.ship.md" "$CLAUDE_MD" "CLAUDE.md" || true
fi

echo ""
echo -e "${GREEN}${BOLD}Ship instalado em ${COMMANDS_DIR}${NC}"
echo ""
echo -e "Pipeline commands:"
echo -e "  ${BOLD}/ship:init${NC}              — Initialize Ship (detect stack, create config)"
echo -e "  ${BOLD}/ship:spec${NC}              — Specify feature, decompose into tasks"
echo -e "  ${BOLD}/ship:run${NC}               — Full pipeline for a task (develop → homologation)"
echo -e "  ${BOLD}/ship:develop${NC}           — Implement code"
echo -e "  ${BOLD}/ship:test${NC}              — Generate & run tests"
echo -e "  ${BOLD}/ship:perf${NC}              — Performance analysis (diff)"
echo -e "  ${BOLD}/ship:security${NC}          — Security scan (diff)"
echo -e "  ${BOLD}/ship:review${NC}            — Code review"
echo -e "  ${BOLD}/ship:analyze${NC}           — Drift detection (spec→code→tests)"
echo -e "  ${BOLD}/ship:homolog${NC}           — User homologation"
echo -e "  ${BOLD}/ship:pr${NC}               — Create pull request"
echo ""
echo -e "Audit commands (project-wide):"
echo -e "  ${BOLD}/ship:audit:run${NC}         — Run all applicable audits in parallel"
echo -e "  ${BOLD}/ship:audit:backend${NC}     — Full backend performance audit"
echo -e "  ${BOLD}/ship:audit:frontend${NC}    — Full frontend performance audit"
echo -e "  ${BOLD}/ship:audit:database${NC}    — Full database audit (MongoDB/PostgreSQL/MySQL)"
echo -e "  ${BOLD}/ship:audit:security${NC}    — Full AppSec audit (OWASP Top 10)"
echo ""
echo -e "${BLUE}Next step:${NC} Run ${BOLD}/ship:init${NC} in Claude Code to configure your project."
echo ""
