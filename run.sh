#!/usr/bin/env bash
# CPM Panel — quick start for development / manual use
# Usage: bash run.sh
set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'

echo -e "${BOLD}${BLUE}Starting CPM Panel...${NC}"

# Build API
echo -e "${BLUE}[1/3] Building API server...${NC}"
pnpm --filter @workspace/api-server run build

# Build frontend
echo -e "${BLUE}[2/3] Building frontend...${NC}"
pnpm --filter @workspace/cpm-panel run build

# Start API server in background
echo -e "${BLUE}[3/3] Starting services...${NC}"
export NODE_ENV=production
export PORT="${PORT:-8080}"

node --enable-source-maps artifacts/api-server/dist/index.mjs &
API_PID=$!

echo -e "${GREEN}${BOLD}CPM Panel running!${NC}"
echo -e "  API server: http://localhost:${PORT}/api/healthz  (PID $API_PID)"
echo -e "  Frontend:   serve artifacts/cpm-panel/dist/ from any web server"
echo -e "  Press Ctrl+C to stop."

trap "kill $API_PID 2>/dev/null; echo 'Stopped.'" EXIT INT TERM
wait $API_PID
