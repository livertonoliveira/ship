#!/bin/bash

# Ship — Development Pipeline Framework
# Update script: overwrites all Ship command files with the latest version.
# Always overwrites — no prompts, no diff checks.

set -e

SHIP_REPO="https://raw.githubusercontent.com/livertonoliveira/ship/main"
COMMANDS_DIR=".claude/commands/ship"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

echo ""
echo -e "${BOLD}⚒️  Ship Update${NC}"
echo ""

if [ ! -d "$COMMANDS_DIR" ]; then
  echo -e "${RED}Ship is not installed in this project.${NC}"
  echo -e "Run the installer first:"
  echo -e "  curl -sL https://raw.githubusercontent.com/livertonoliveira/ship/main/install.sh | bash"
  exit 1
fi

mkdir -p "$COMMANDS_DIR/audit"

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

cleanup_harness_hooks

PIPELINE_COMMANDS=(
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

UPDATED=()
FAILED=()

download_and_overwrite() {
  local url="$1"
  local dest="$2"
  local label="$3"

  local tmp
  local http_code
  tmp=$(mktemp)
  http_code=$(curl -sL -w "%{http_code}" "$url" -o "$tmp")

  if [ "$http_code" != "200" ]; then
    echo -e "  ${RED}✗${NC} ${label} (HTTP ${http_code})"
    FAILED+=("$label")
    rm -f "$tmp"
    return
  fi

  if diff -q "$dest" "$tmp" > /dev/null 2>&1; then
    echo -e "  ${NC}–${NC} ${label} (up to date)"
  else
    cp "$tmp" "$dest"
    echo -e "  ${GREEN}✓${NC} ${label} (updated)"
    UPDATED+=("$label")
  fi

  rm -f "$tmp"
}

echo -e "${BLUE}Pipeline commands:${NC}"
for cmd in "${PIPELINE_COMMANDS[@]}"; do
  dest="${COMMANDS_DIR}/${cmd}"
  # Create file if it doesn't exist yet (new command added to Ship)
  touch "$dest" 2>/dev/null || true
  skill_name="${cmd%.md}"
  download_and_overwrite "${SHIP_REPO}/plugins/ship/skills/${skill_name}/SKILL.md" "$dest" "$cmd"
done

echo ""
echo -e "${BLUE}Audit commands:${NC}"
for cmd in "${AUDIT_COMMANDS[@]}"; do
  dest="${COMMANDS_DIR}/audit/${cmd}"
  touch "$dest" 2>/dev/null || true
  skill_name="${cmd%.md}"
  download_and_overwrite "${SHIP_REPO}/plugins/ship/skills/audit/${skill_name}/SKILL.md" "$dest" "audit/${cmd}"
done

echo ""
echo -e "${BOLD}Summary:${NC} ${#UPDATED[@]} updated, ${#FAILED[@]} failed"

if [ ${#UPDATED[@]} -gt 0 ]; then
  echo -e "${GREEN}Updated files:${NC}"
  for f in "${UPDATED[@]}"; do
    echo "  • $f"
  done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo -e "${RED}Failed to fetch:${NC}"
  for f in "${FAILED[@]}"; do
    echo "  • $f"
  done
  exit 1
fi

echo -e "${GREEN}Ship atualizado. Hooks do harness removidos (se existiam).${NC}"
echo ""
