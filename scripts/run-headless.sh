#!/usr/bin/env bash
# =============================================================================
#  run-headless.sh - chay Claude Code o che do KHONG TUONG TAC (headless)
#
#  Chay BEN TRONG container claude-code (khong phai tren host). Vi du tren VPS:
#      docker compose exec -u coder claude-code \
#          bash /home/coder/workspace/scripts/run-headless.sh "Prompt cua ban"
#  hoac tu terminal cua code-server:
#      bash scripts/run-headless.sh "Prompt cua ban"
#      bash scripts/run-headless.sh --file duong/dan/prompt.txt
#
#  Ghi stdout + stderr ra file log co timestamp trong workspace de ban xem lai
#  sau ma khong can ngoi canh.
#
#  Co che headless da XAC MINH voi tai lieu chinh thuc (code.claude.com, CLI
#  reference, kiem tra thang 8/2026):
#    -p / --print                : chay mot lan roi thoat, khong vao che do
#                                  tuong tac. Doc prompt tu tham so hoac stdin.
#    --output-format text|json|stream-json : dinh dang dau ra cho che do print.
#    --allowedTools "..."        : cap truoc danh sach tool duoc chay KHONG hoi.
#    --dangerously-skip-permissions : BO QUA moi hoi quyen (nguy hiem - xem duoi).
#
# =============================================================================
#  !!! CANH BAO QUAN TRONG VE QUYEN TOOL !!!
#
#  O che do tuong tac, moi khi Claude muon chay lenh shell / sua file no HOI ban
#  truoc. O che do headless KHONG CO AI de hoi. Vi vay:
#
#    - Mac dinh script nay CHI truyen -p (print). Neu prompt yeu cau dung tool
#      chua duoc cap quyen, Claude se dung lai va khong lam gi - AN TOAN nhung
#      co the "khong chay duoc gi".
#
#    - Cach DUNG khuyen nghi: cap truoc dung nhung tool ban tin bang bien
#      ALLOWED_TOOLS ben duoi (vi du chi cho doc file va chay git log), thay vi
#      mo toang.
#
#    - Cach NGUY HIEM: --dangerously-skip-permissions cho phep Claude chay BAT KY
#      lenh nao (ke ca xoa file, gui mang) MA KHONG HOI. Chi bat khi ban hieu ro
#      rui ro va tin tuong prompt. Script nay KHONG mac dinh bat co do. Muon bat,
#      dat bien moi truong DANGEROUS=1 khi goi - va tu chiu trach nhiem.
# =============================================================================
set -euo pipefail

# --- Doc tham so -------------------------------------------------------------
PROMPT=""
if [ "${1:-}" = "--file" ]; then
    [ -n "${2:-}" ] || { echo "Thieu duong dan sau --file" >&2; exit 1; }
    [ -f "$2" ] || { echo "Khong thay file prompt: $2" >&2; exit 1; }
    PROMPT="$(cat "$2")"
elif [ -n "${1:-}" ]; then
    PROMPT="$1"
else
    echo "Cach dung: $0 \"<prompt>\"   hoac   $0 --file <duong-dan-prompt>" >&2
    exit 1
fi

# --- PATH: bao dam thay duoc `claude` du chay tu login shell hay exec ---------
export PATH="/home/coder/.npm-global/bin:/opt/venv/bin:${PATH}"
command -v claude >/dev/null 2>&1 || { echo "Khong tim thay lenh 'claude'." >&2; exit 1; }

# --- Thu muc log: /home/coder/workspace/logs/ --------------------------------
LOG_DIR="${HOME:-/home/coder}/workspace/logs"
mkdir -p "${LOG_DIR}"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/claude-headless-${TS}.log"

# --- Danh sach tool duoc cap quyen truoc (KHONG hoi khi chay) ----------------
# Mac dinh chi cho cac tool doc-only an toan. Them/bot tuy nhu cau. Cu phap
# theo tai lieu permission rule, vi du: "Bash(git log:*)" "Bash(git diff:*)".
# De TRONG mang nay neu ban muon Claude van hoi (nhung headless se dung lai).
ALLOWED_TOOLS=(
    "Read"
    "Grep"
    "Glob"
    "Bash(git log:*)"
    "Bash(git status:*)"
    "Bash(git diff:*)"
)

# --- Rap cac co dong lenh -----------------------------------------------------
ARGS=(-p "${PROMPT}" --output-format text)

if [ "${DANGEROUS:-0}" = "1" ]; then
    # NGUOI DUNG DA CHU DONG BAT che do bo qua moi hoi quyen. Rui ro cao.
    echo "[run-headless] CANH BAO: --dangerously-skip-permissions dang BAT (DANGEROUS=1)." | tee -a "${LOG_FILE}"
    ARGS+=(--dangerously-skip-permissions)
else
    # Cap truoc danh sach tool an toan; ngoai danh sach nay Claude se dung lai.
    if [ "${#ALLOWED_TOOLS[@]}" -gt 0 ]; then
        ARGS+=(--allowedTools "${ALLOWED_TOOLS[@]}")
    fi
fi

# --- Chay va ghi log ----------------------------------------------------------
{
    echo "===== claude headless: ${TS} ====="
    echo "Prompt: ${PROMPT}"
    echo "Allowed tools: ${ALLOWED_TOOLS[*]:-<none>}"
    echo "Dangerous mode: ${DANGEROUS:-0}"
    echo "----------------------------------------"
} | tee -a "${LOG_FILE}"

echo "[run-headless] Dang chay... Log: ${LOG_FILE}"

# Ghi ca stdout lan stderr vao log, van hien ra man hinh.
set +e
claude "${ARGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
STATUS=${PIPESTATUS[0]}
set -e

echo "----------------------------------------" | tee -a "${LOG_FILE}"
echo "[run-headless] Ket thuc voi ma thoat: ${STATUS}. Log: ${LOG_FILE}" | tee -a "${LOG_FILE}"
exit "${STATUS}"
