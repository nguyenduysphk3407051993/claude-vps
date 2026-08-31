#!/usr/bin/env bash
# =============================================================================
#  backup.sh - Sao luu toan bo du lieu cua stack
#
#      bash scripts/backup.sh
#
#  Sao luu nhung gi:
#    1. Named volume claude_config  -> TOKEN DANG NHAP CLAUDE CODE (quan trong nhat)
#    2. Named volume code_config    -> cai dat + extension cua code-server
#    3. Thu muc ./workspace         -> ma nguon cua ban (bind mount, tar truc tiep)
#    4. .env                        -> mat khau, hash BasicAuth
#
#  KHONG sao luu chung chi Let's Encrypt: chung thuoc stack Traefik rieng
#  (vd /home/N8N/traefik-stack/letsencrypt/acme.json). Sao luu ben do neu can.
#
#  Ket qua: ./backups/claude-vps-<YYYYmmdd-HHMMSS>.tar.gz
#  Tu dong xoay vong, mac dinh giu 7 ban gan nhat (doi bang bien KEEP).
#
#  Tuy chon:
#      KEEP=14 bash scripts/backup.sh     # giu 14 ban
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

BACKUP_DIR="${ROOT_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/claude-vps-${TIMESTAMP}.tar.gz"
STAGING="${BACKUP_DIR}/.staging-${TIMESTAMP}"

# So ban sao luu giu lai
KEEP="${KEEP:-7}"

# Ten named volume - dat tuong minh bang khoa "name:" trong docker-compose.yml
VOLUMES="claude_config code_config"

# Image dung de doc named volume (rat nho, chi dung tam thoi)
HELPER_IMAGE="alpine:3.20"

if [ -t 1 ]; then
    C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'; C_RED=$'\033[0;31m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'
else
    C_GRN=''; C_YLW=''; C_RED=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

step() { printf '\n%s==> %s%s\n' "${C_BLU}${C_BLD}" "$*" "${C_OFF}"; }
ok()   { printf '%s  [OK]%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; }
warn() { printf '%s  [!!]%s %s\n' "${C_YLW}" "${C_OFF}" "$*"; }
die()  { printf '%s  [XX]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; exit 1; }

# Don dep thu muc tam du script that bai giua chung
cleanup() { rm -rf "${STAGING}" 2>/dev/null || true; }
trap cleanup EXIT

# --- Chon lenh docker (co the can sudo) -------------------------------------
command -v docker >/dev/null 2>&1 || die "Khong tim thay lenh docker."
if docker info >/dev/null 2>&1; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
    warn "User hien tai khong goi duoc Docker daemon - dung sudo."
fi

mkdir -p "${BACKUP_DIR}" "${STAGING}"

# =============================================================================
#  1. Named volume  ->  tar.gz (qua container alpine tam thoi)
# =============================================================================
step "Sao luu named volume"

for vol in ${VOLUMES}; do
    if ! ${DOCKER} volume inspect "${vol}" >/dev/null 2>&1; then
        warn "Volume '${vol}' khong ton tai - bo qua"
        continue
    fi
    ${DOCKER} run --rm \
        -v "${vol}:/data:ro" \
        -v "${STAGING}:/backup" \
        "${HELPER_IMAGE}" \
        tar czf "/backup/${vol}.tar.gz" -C /data . \
        || die "Sao luu volume '${vol}' that bai."
    ok "${vol} -> ${vol}.tar.gz"
done

# =============================================================================
#  2. ./workspace  ->  tar thuong (day la BIND MOUNT tren host, khong can docker)
# =============================================================================
step "Sao luu thu muc ./workspace"

if [ -d "${ROOT_DIR}/workspace" ]; then
    # File trong workspace thuoc uid 1000 (user coder). Neu user dang chay khong
    # doc duoc thi thu lai bang sudo.
    if tar czf "${STAGING}/workspace.tar.gz" -C "${ROOT_DIR}" workspace 2>/dev/null; then
        ok "workspace -> workspace.tar.gz"
    elif sudo tar czf "${STAGING}/workspace.tar.gz" -C "${ROOT_DIR}" workspace; then
        ok "workspace -> workspace.tar.gz (dung sudo)"
    else
        die "Khong doc duoc ./workspace"
    fi
else
    warn "Khong thay thu muc ./workspace - bo qua"
fi

# =============================================================================
#  3. Cac file cau hinh
# =============================================================================
step "Sao luu file cau hinh"

mkdir -p "${STAGING}/config"
for f in .env docker-compose.yml Dockerfile; do
    if [ -f "${ROOT_DIR}/${f}" ]; then
        mkdir -p "${STAGING}/config/$(dirname "${f}")"
        cp -p "${ROOT_DIR}/${f}" "${STAGING}/config/${f}"
        ok "${f}"
    else
        warn "${f} khong ton tai - bo qua"
    fi
done

# =============================================================================
#  4. Dong goi
# =============================================================================
step "Dong goi"

tar czf "${ARCHIVE}" -C "${STAGING}" .
chmod 600 "${ARCHIVE}"
SIZE="$(du -h "${ARCHIVE}" | cut -f1)"
ok "Da tao ${ARCHIVE} (${SIZE})"

# =============================================================================
#  5. Xoay vong
# =============================================================================
step "Xoay vong (giu ${KEEP} ban gan nhat)"

# ls -1t sap xep theo thoi gian giam dan; tail bo qua ${KEEP} ban dau tien.
OLD="$(ls -1t "${BACKUP_DIR}"/claude-vps-*.tar.gz 2>/dev/null | tail -n "+$((KEEP + 1))" || true)"
if [ -n "${OLD}" ]; then
    printf '%s\n' "${OLD}" | while IFS= read -r f; do
        rm -f "${f}"
        ok "Da xoa ban cu: $(basename "${f}")"
    done
else
    ok "Chua co ban nao can xoa"
fi

REMAIN="$(ls -1 "${BACKUP_DIR}"/claude-vps-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
ok "Hien co ${REMAIN} ban sao luu trong ${BACKUP_DIR}"

# =============================================================================
#  HUONG DAN PHUC HOI
# =============================================================================
cat <<EOF

${C_BLD}CACH PHUC HOI TU BAN SAO LUU NAY${C_OFF}

  # 0) Dung stack (KHONG dung -v, se xoa sach volume)
  docker compose down

  # 1) Giai nen ban sao luu ra thu muc tam
  mkdir -p /tmp/restore && tar xzf ${ARCHIVE} -C /tmp/restore

  # 2) Phuc hoi named volume (token dang nhap Claude + cai dat code-server)
  docker volume create claude_config
  docker run --rm -v claude_config:/data -v /tmp/restore:/backup ${HELPER_IMAGE} \\
      sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf /backup/claude_config.tar.gz -C /data'

  docker volume create code_config
  docker run --rm -v code_config:/data -v /tmp/restore:/backup ${HELPER_IMAGE} \\
      sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf /backup/code_config.tar.gz -C /data'

  # 3) Phuc hoi ma nguon (bind mount) - giai nen ngay tai thu muc du an
  tar xzf /tmp/restore/workspace.tar.gz -C ${ROOT_DIR}
  sudo chown -R 1000:1000 ${ROOT_DIR}/workspace

  # 4) Phuc hoi cau hinh
  cp /tmp/restore/config/.env  ${ROOT_DIR}/.env
  chmod 600 ${ROOT_DIR}/.env

  # 5) Khoi dong lai
  docker compose up -d
  rm -rf /tmp/restore

${C_YLW}Ban sao luu chua MAT KHAU va PRIVATE KEY - cat giu o noi an toan,
tot nhat la sao chep ra ngoai VPS:  scp user@vps:${ARCHIVE} .${C_OFF}
EOF
