#!/usr/bin/env bash
# =============================================================================
#  setup.sh - Cai dat va trien khai stack Claude Code + code-server
#
#  YEU CAU: VPS da co san mot Traefik dang chay, so huu network "traefik-network",
#  entrypoint "websecure" va certresolver "letsencrypt". Stack nay KHONG tu dung
#  Traefik rieng - no chi gan nhan (label) de Traefik san tao route.
#
#  Chay tren VPS Linux (Ubuntu/Debian khuyen nghi):
#      bash scripts/setup.sh
#
#  Tuy chon:
#      --skip-docker-install   Bo qua buoc cai Docker (khi da co san)
#      --regen-auth            Sinh lai mat khau BasicAuth va mat khau code-server
#      --no-deploy             Chi chuan bi cau hinh, khong chay docker compose up
#      -h | --help             Xem tro giup
#
#  Script chay lai nhieu lan an toan (idempotent).
# =============================================================================
set -euo pipefail

# --- Duong dan goc cua du an (thu muc cha cua scripts/) ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"
WORKSPACE_DIR="${ROOT_DIR}/workspace"

# uid/gid cua user "coder" trong image code-server (co dinh la 1000:1000)
CODER_UID=1000
CODER_GID=1000

# --- Co dong lenh -----------------------------------------------------------
SKIP_DOCKER_INSTALL=0
REGEN_AUTH=0
NO_DEPLOY=0

# --- Mau sac ----------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

step() { printf '\n%s==> %s%s\n' "${C_BLU}${C_BLD}" "$*" "${C_OFF}"; }
ok()   { printf '%s  [OK]%s %s\n'   "${C_GRN}" "${C_OFF}" "$*"; }
warn() { printf '%s  [!!]%s %s\n'   "${C_YLW}" "${C_OFF}" "$*"; }
err()  { printf '%s  [XX]%s %s\n'   "${C_RED}" "${C_OFF}" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-docker-install) SKIP_DOCKER_INSTALL=1 ;;
        --regen-auth)          REGEN_AUTH=1 ;;
        --no-deploy)           NO_DEPLOY=1 ;;
        -h|--help)             usage ;;
        *) die "Tham so khong hop le: $1 (dung --help de xem tro giup)" ;;
    esac
    shift
done

# =============================================================================
#  HAM TIEN ICH
# =============================================================================

# Doc gia tri mot bien trong .env (tra ve chuoi tho, chua un-escape $$)
get_env() {
    local key="$1"
    [ -f "${ENV_FILE}" ] || return 0
    sed -n "s/^[[:space:]]*${key}=//p" "${ENV_FILE}" | head -n 1
}

# Ghi / cap nhat mot bien trong .env.
# Dung awk voi ENVIRON de gia tri KHONG bi dien giai lai (hash bcrypt co ky tu
# $ . / rat de lam hong sed).
set_env() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp)"
    if grep -qE "^[[:space:]]*${key}=" "${ENV_FILE}"; then
        K="${key}" V="${value}" awk '
            BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
            (done == 0) && ($0 ~ "^[[:space:]]*" k "=") { print k "=" v; done = 1; next }
            { print }
        ' "${ENV_FILE}" > "${tmp}"
        mv "${tmp}" "${ENV_FILE}"
    else
        rm -f "${tmp}"
        printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
}

# Nhan doi moi ky tu "$" -> "$$" (bat buoc cho Docker Compose).
escape_dollar() {
    printf '%s' "$1" | sed 's/\$/$$/g'
}

# Sinh chuoi ngau nhien chi gom chu va so (tranh moi rac roi escaping).
rand_str() {
    local n="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${n}" || true
    echo
}

# Lenh compose (docker compose v2, fallback docker-compose v1)
COMPOSE=""
detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        return 1
    fi
    return 0
}

# =============================================================================
#  BUOC 1 - Kiem tra moi truong
# =============================================================================
step "Buoc 1/9: Kiem tra moi truong"

if [ "$(uname -s)" != "Linux" ]; then
    die "Script nay chi chay tren Linux. He dieu hanh hien tai: $(uname -s)"
fi
ok "He dieu hanh: Linux ($(uname -m))"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    warn "Dang chay bang root. Nen tao user thuong roi them vao nhom docker."
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    # Kich hoat cache sudo ngay tu dau de khong bi hoi mat khau giua chung
    ${SUDO} -v || die "Can quyen sudo de tiep tuc."
    ok "Co quyen sudo"
else
    die "Khong phai root va khong co sudo. Khong the tiep tuc."
fi

for tool in curl sed awk grep tar; do
    command -v "${tool}" >/dev/null 2>&1 || die "Thieu lenh bat buoc: ${tool}"
done
ok "Da co day du cong cu co ban"

# =============================================================================
#  BUOC 2 - Cai Docker neu can
# =============================================================================
step "Buoc 2/9: Docker Engine + Compose plugin"

if [ "${SKIP_DOCKER_INSTALL}" -eq 1 ]; then
    warn "Bo qua cai Docker theo yeu cau (--skip-docker-install)"
elif command -v docker >/dev/null 2>&1 && detect_compose; then
    ok "Docker da co san: $(docker --version)"
else
    warn "Chua co Docker (hoac thieu compose plugin) - tien hanh cai dat"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    ${SUDO} sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    ${SUDO} systemctl enable --now docker || true
    if [ -n "${SUDO}" ]; then
        ${SUDO} usermod -aG docker "$(id -un)" || true
        warn "Da them $(id -un) vao nhom docker. Dang xuat/dang nhap lai de co hieu luc."
    fi
fi

detect_compose || die "Khong tim thay 'docker compose'. Cai Docker Compose plugin roi chay lai."
ok "Lenh compose: ${COMPOSE}"

if ! docker info >/dev/null 2>&1; then
    warn "Khong goi duoc Docker daemon bang user hien tai - se dung sudo cho cac lenh docker."
    COMPOSE="${SUDO} ${COMPOSE}"
    DOCKER="${SUDO} docker"
else
    DOCKER="docker"
fi

# =============================================================================
#  BUOC 3 - Thu muc va file can thiet
# =============================================================================
step "Buoc 3/9: Chuan bi thu muc va quyen"

# Khong con acme.json o day: chung chi do Traefik san quan ly trong stack cua no.

# --- workspace: BIND MOUNT ra host --------------------------------------------
# Container chay bang user "coder" uid/gid 1000. Neu thu muc tren host thuoc
# root thi code-server khong ghi duoc file nao => phai chown 1000:1000.
mkdir -p "${WORKSPACE_DIR}"
touch "${WORKSPACE_DIR}/.gitkeep"
if [ -n "${SUDO}" ]; then
    ${SUDO} chown -R "${CODER_UID}:${CODER_GID}" "${WORKSPACE_DIR}"
else
    chown -R "${CODER_UID}:${CODER_GID}" "${WORKSPACE_DIR}"
fi
ok "workspace/ da thuoc ${CODER_UID}:${CODER_GID} (user coder trong container)"

mkdir -p "${ROOT_DIR}/backups"

# --- Chong CRLF: neu file duoc soan tren Windows -----------------------------
if grep -qU $'\r' "${ROOT_DIR}/docker/entrypoint.d/10-claude-config.sh" 2>/dev/null; then
    warn "Phat hien ky tu CRLF trong script - dang tu dong chuyen ve LF"
    find "${ROOT_DIR}" -type f \( -name '*.sh' -o -name 'Dockerfile' -o -name '*.yml' \
        -o -name '*.template' \) -exec sed -i 's/\r$//' {} +
    ok "Da chuyen toan bo file ve dinh dang LF"
fi

# =============================================================================
#  BUOC 4 - File .env
# =============================================================================
step "Buoc 4/9: File cau hinh .env"

if [ ! -f "${ENV_FILE}" ]; then
    [ -f "${ENV_EXAMPLE}" ] || die "Khong thay ${ENV_EXAMPLE}"
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    printf '\n'
    err "Vua tao file .env tu .env.example."
    printf '%s\n' "${C_BLD}Hay mo file .env va dien gia tri BAT BUOC:${C_OFF}"
    printf '%s\n' "    DOMAIN=       # ten mien da tro DNS ve VPS nay"
    printf '\n%s\n' "    nano ${ENV_FILE}"
    printf '%s\n\n' "Sua xong thi chay lai: bash scripts/setup.sh"
    exit 1
fi
chmod 600 "${ENV_FILE}"
ok "Da co .env"

DOMAIN="$(get_env DOMAIN)"

[ -n "${DOMAIN}" ] || die "DOMAIN chua duoc dien trong .env"
[ "${DOMAIN}" != "code.example.com" ] || die "DOMAIN van con la gia tri mau. Sua .env truoc da."

case "${DOMAIN}" in
    *.*) : ;;
    *) die "DOMAIN='${DOMAIN}' trong khong giong mot ten mien hop le." ;;
esac
ok "DOMAIN=${DOMAIN}"

# =============================================================================
#  BUOC 5 - Sinh mat khau va hash BasicAuth
# =============================================================================
step "Buoc 5/9: Mat khau va BasicAuth"

BASIC_AUTH_USER="$(get_env BASIC_AUTH_USER)"
[ -n "${BASIC_AUTH_USER}" ] || BASIC_AUTH_USER="admin"
EXISTING_HASH="$(get_env BASIC_AUTH_HASH)"

BASIC_AUTH_PLAIN=""   # chi ton tai trong lan chay nay, dung de tu kiem tra o buoc 10

if [ -n "${EXISTING_HASH}" ] && [ "${REGEN_AUTH}" -eq 0 ]; then
    ok "BASIC_AUTH_HASH da co san - giu nguyen (dung --regen-auth de sinh lai)"
    RAW_HASH=""
else
    BASIC_AUTH_PLAIN="$(rand_str 24)"
    [ -n "${BASIC_AUTH_PLAIN}" ] || die "Khong sinh duoc mat khau ngau nhien."

    if command -v htpasswd >/dev/null 2>&1; then
        # -n: in ra stdout, -b: lay mat khau tu tham so, -B: bcrypt
        HTLINE="$(htpasswd -nbB "${BASIC_AUTH_USER}" "${BASIC_AUTH_PLAIN}")"
        HASH_ALGO="bcrypt"
    else
        warn "Khong co htpasswd (goi apache2-utils) - dung openssl passwd -apr1 thay the"
        command -v openssl >/dev/null 2>&1 || die "Thieu ca htpasswd lan openssl. Cai: ${SUDO} apt-get install -y apache2-utils"
        HTLINE="${BASIC_AUTH_USER}:$(openssl passwd -apr1 "${BASIC_AUTH_PLAIN}")"
        HASH_ALGO="apr1(md5)"
    fi

    # Tach "user:hash" - hash CO CHUA dau ":"? Khong, nhung van cat theo dau ":" dau tien.
    BASIC_AUTH_USER="${HTLINE%%:*}"
    RAW_HASH="${HTLINE#*:}"
    [ -n "${RAW_HASH}" ] || die "Khong tach duoc hash tu chuoi htpasswd."

    # !!! DIEM DE SAI NHAT CUA CA STACK !!!
    # Docker Compose noi suy bien NGAY TRONG file .env, nen moi "$" trong hash
    # phai duoc viet thanh "$$" tai day.
    ESCAPED_HASH="$(escape_dollar "${RAW_HASH}")"

    set_env BASIC_AUTH_USER "${BASIC_AUTH_USER}"
    set_env BASIC_AUTH_HASH "${ESCAPED_HASH}"
    ok "Da sinh hash ${HASH_ALGO} cho user '${BASIC_AUTH_USER}' va escape \$ -> \$\$"
fi

# --- Mat khau cua chinh code-server -----------------------------------------
CS_PASS="$(get_env CODE_SERVER_PASSWORD)"
if [ -z "${CS_PASS}" ] || [ "${CS_PASS}" = "doi-mat-khau-nay-di" ] || [ "${REGEN_AUTH}" -eq 1 ]; then
    CS_PASS="$(rand_str 24)"
    set_env CODE_SERVER_PASSWORD "${CS_PASS}"
    ok "Da sinh mat khau moi cho code-server"
    CS_PASS_NEW=1
else
    ok "CODE_SERVER_PASSWORD da duoc dat - giu nguyen"
    CS_PASS_NEW=0
fi

# =============================================================================
#  BUOC 6 - TU KIEM CHUNG ESCAPING (quan trong)
# =============================================================================
step "Buoc 6/9: Kiem chung nhan doi \$ trong BASIC_AUTH_HASH"

CONFIG_OUT=""
if ! CONFIG_OUT="$(${COMPOSE} config 2>&1)"; then
    err "Lenh '${COMPOSE} config' bao loi:"
    printf '%s\n' "${CONFIG_OUT}"
    die "Sua loi cu phap trong docker-compose.yml / .env roi chay lai."
fi
ok "docker compose config: cu phap hop le"

RESOLVED="$(printf '%s\n' "${CONFIG_OUT}" \
    | grep -m1 'traefik\.http\.middlewares\.claude-auth\.basicauth\.users' \
    | sed -e 's/^[^:]*basicauth\.users[":]*[[:space:]]*//' \
          -e 's/^[=:][[:space:]]*//' \
          -e 's/^"//' -e 's/"$//' \
          -e "s/^'//" -e "s/'$//" \
          -e 's/[[:space:]]*$//')"

if [ -z "${RESOLVED}" ]; then
    warn "Khong doc duoc nhan basicauth tu 'compose config' - bo qua buoc kiem chung."
elif printf '%s' "${RESOLVED}" | grep -q '\$\$'; then
    err "Nhan basicauth SAU KHI compose xu ly VAN con '\$\$':"
    printf '    %s\n' "${RESOLVED}"
    die "Nghia la hash trong .env bi escape SAI (nhan doi 2 lan). Chay lai voi --regen-auth."
elif [ -n "${RAW_HASH}" ]; then
    EXPECTED="${BASIC_AUTH_USER}:${RAW_HASH}"
    if [ "${RESOLVED}" = "${EXPECTED}" ]; then
        ok "Escaping chinh xac: hash sau khi compose giai ma trung voi hash goc"
    else
        err "Hash sau khi compose giai ma KHONG trung hash goc."
        printf '    Mong doi : %s\n' "${EXPECTED}"
        printf '    Thuc te  : %s\n' "${RESOLVED}"
        die "Xem muc 'BasicAuth luon bao sai mat khau' trong HUONG-DAN.md."
    fi
else
    ok "Nhan basicauth da duoc giai ma, khong con ky tu '\$\$' thua"
fi

# =============================================================================
#  BUOC 7 - Kiem tra DNS va tuong lua
# =============================================================================
step "Buoc 7/9: DNS va tuong lua"

PUBLIC_IP="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || \
             curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo '')"
DOMAIN_IP="$(getent hosts "${DOMAIN}" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"

if [ -z "${DOMAIN_IP}" ]; then
    warn "Khong phan giai duoc '${DOMAIN}'. Ban ghi DNS A da tao chua?"
    warn "Let's Encrypt SE THAT BAI neu ten mien chua tro ve VPS nay."
elif [ -z "${PUBLIC_IP}" ]; then
    warn "Khong lay duoc IP public de doi chieu. DNS tra ve: ${DOMAIN_IP}"
elif [ "${DOMAIN_IP}" = "${PUBLIC_IP}" ]; then
    ok "DNS chinh xac: ${DOMAIN} -> ${DOMAIN_IP}"
else
    warn "DNS LECH: ${DOMAIN} -> ${DOMAIN_IP} nhung IP VPS la ${PUBLIC_IP}"
    warn "Neu dang dung Cloudflare proxy (dam may cam), hay tat proxy (DNS only)."
fi

if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -q 'Status: active'; then
    ${SUDO} ufw allow 80/tcp  >/dev/null 2>&1 || true
    ${SUDO} ufw allow 443/tcp >/dev/null 2>&1 || true
    ok "ufw dang bat - da mo cong 80 va 443"
else
    ok "ufw khong hoat dong - bo qua (nho kiem tra firewall cua nha cung cap VPS)"
fi

# =============================================================================
#  BUOC 8 - Build va khoi dong
# =============================================================================
step "Buoc 8/9: Build image va khoi dong stack"

if [ "${NO_DEPLOY}" -eq 1 ]; then
    warn "Bo qua trien khai theo yeu cau (--no-deploy)"
else
    ${COMPOSE} up -d --build
    ok "Da goi 'compose up -d --build'"

    printf '  Cho container claude-code chuyen sang trang thai healthy'
    HEALTH="unknown"
    for _ in $(seq 1 60); do
        HEALTH="$(${DOCKER} inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' claude-code 2>/dev/null || echo 'missing')"
        [ "${HEALTH}" = "healthy" ] && break
        printf '.'
        sleep 5
    done
    printf '\n'
    if [ "${HEALTH}" = "healthy" ]; then
        ok "claude-code: healthy"
    else
        warn "claude-code hien o trang thai '${HEALTH}'. Xem log: ${COMPOSE} logs claude-code"
    fi
fi

# =============================================================================
#  BUOC 9 - Kiem chung dau-cuoi qua HTTPS
# =============================================================================
step "Buoc 9/9: Kiem chung truy cap qua HTTPS"

if [ "${NO_DEPLOY}" -eq 1 ]; then
    warn "Bo qua (--no-deploy)"
else
    warn "Let's Encrypt can 30-90 giay de cap chung chi lan dau - dang cho..."
    sleep 20

    CODE_NOAUTH=""
    for _ in $(seq 1 12); do
        CODE_NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/" 2>/dev/null || echo '000')"
        [ "${CODE_NOAUTH}" != "000" ] && break
        printf '.'
        sleep 10
    done
    printf '\n'

    case "${CODE_NOAUTH}" in
        401)
            ok "Khong kem thong tin dang nhap -> HTTP 401 (dung nhu mong doi)"
            ;;
        000)
            err "Khong ket noi duoc toi https://${DOMAIN}/"
            warn "Kiem tra: DNS, cong 443, va: ${COMPOSE} logs traefik"
            ;;
        *)
            warn "Nhan duoc HTTP ${CODE_NOAUTH} (mong doi 401). Xem: ${COMPOSE} logs traefik"
            ;;
    esac

    if [ -n "${BASIC_AUTH_PLAIN}" ] && [ "${CODE_NOAUTH}" = "401" ]; then
        CODE_AUTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
            -u "${BASIC_AUTH_USER}:${BASIC_AUTH_PLAIN}" "https://${DOMAIN}/" 2>/dev/null || echo '000')"
        case "${CODE_AUTH}" in
            200|302)
                ok "Co thong tin dang nhap -> HTTP ${CODE_AUTH}. BasicAuth HOAT DONG."
                ;;
            401)
                err "Van 401 du da gui dung mat khau -> loi escaping hash."
                err "Chan doan: ${COMPOSE} config | grep basicauth"
                ;;
            *)
                warn "Nhan HTTP ${CODE_AUTH} (mong doi 200 hoac 302)."
                ;;
        esac
    elif [ -z "${BASIC_AUTH_PLAIN}" ]; then
        warn "Khong biet mat khau BasicAuth dang dung (khong sinh moi trong lan chay nay)"
        warn "=> bo qua kiem tra co xac thuc. Dung --regen-auth neu ban da quen mat khau."
    fi
fi

# =============================================================================
#  TONG KET
# =============================================================================
printf '\n%s============================================================%s\n' "${C_GRN}${C_BLD}" "${C_OFF}"
printf '%s  HOAN TAT%s\n' "${C_GRN}${C_BLD}" "${C_OFF}"
printf '%s============================================================%s\n\n' "${C_GRN}${C_BLD}" "${C_OFF}"

printf '  Dia chi truy cap : %shttps://%s%s\n' "${C_BLD}" "${DOMAIN}" "${C_OFF}"
printf '  BasicAuth user   : %s\n' "${BASIC_AUTH_USER}"
if [ -n "${BASIC_AUTH_PLAIN}" ]; then
    printf '  BasicAuth pass   : %s%s%s   <-- LUU LAI NGAY, khong hien lai lan sau\n' \
        "${C_BLD}" "${BASIC_AUTH_PLAIN}" "${C_OFF}"
else
    printf '  BasicAuth pass   : (khong doi trong lan chay nay)\n'
fi
if [ "${CS_PASS_NEW}" -eq 1 ]; then
    printf '  code-server pass : %s%s%s   <-- man hinh dang nhap thu 2\n' \
        "${C_BLD}" "${CS_PASS}" "${C_OFF}"
else
    printf '  code-server pass : (xem CODE_SERVER_PASSWORD trong .env)\n'
fi

cat <<EOF

  BUOC TIEP THEO - dang nhap Claude Code lan dau:
    1. Mo https://${DOMAIN} , qua BasicAuth roi qua man hinh mat khau code-server.
    2. Trong VS Code chon: Terminal > New Terminal  (hoac Ctrl + \`)
    3. Go:  claude
    4. Chon "Claude account with subscription", copy URL hien ra, mo o may ca nhan.
    5. Trinh duyet se hien mot MA (thay vi tu chuyen huong lai) - day la hanh vi
       binh thuong khi chay trong container. Copy ma do va dan vao dong nhac
       "Paste code here if prompted" trong terminal.
    6. Kiem tra:  claude --version   va   claude   ->  /status

  Token duoc luu tai /home/coder/.claude/.credentials.json (named volume
  'claude_config'), nen restart hay rebuild deu KHONG mat dang nhap.
  ${C_RED}${C_BLD}CANH BAO: '${COMPOSE} down -v' SE XOA volume => mat dang nhap.${C_OFF}

  Lenh thuong dung:
    ${COMPOSE} ps
    ${COMPOSE} logs -f claude-code
    ${COMPOSE} restart
    bash scripts/backup.sh

  Tai lieu chi tiet: HUONG-DAN.md
EOF
