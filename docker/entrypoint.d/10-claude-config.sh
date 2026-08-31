#!/bin/sh
# =============================================================================
#  Hook khoi dong container - do /usr/bin/entrypoint.sh cua base image goi.
#
#  MUC DICH: bao dam file  ~/.claude.json  nam TRONG named volume claude_config,
#  de khong bi mat khi container bi tao lai.
#
#  Boi canh:
#   - Tai lieu chinh thuc khang dinh: khi da set CLAUDE_CONFIG_DIR tren Linux,
#     file  .credentials.json  (token dang nhap) nam trong thu muc do
#     => da nam trong volume, an toan.
#   - Nhung  ~/.claude.json  (phien dang nhap, cau hinh MCP, danh sach project
#     da tin tuong) la file RIENG, tai lieu KHONG khang dinh ro no co di theo
#     CLAUDE_CONFIG_DIR hay khong.
#   => Script nay la LOP BAO HIEM: chuyen no vao volume roi tao symlink tro ve.
#
#  Dac tinh: POSIX sh, chay lai nhieu lan van an toan (idempotent), va MOI loi
#  deu bi nuot de khong bao gio chan container khoi dong.
# =============================================================================
set -eu

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TARGET="${CFG_DIR}/.claude.json"
LINK="${HOME}/.claude.json"

log() {
    echo "[10-claude-config] $*"
}

main() {
    # Thu muc cau hinh (chinh la diem mount cua volume claude_config)
    mkdir -p "${CFG_DIR}"
    chmod 700 "${CFG_DIR}"

    # Truong hop 1: ~/.claude.json dang la FILE THUONG (khong phai symlink)
    # => day la du lieu that, chuyen vao volume.
    if [ -f "${LINK}" ] && [ ! -L "${LINK}" ]; then
        if [ -e "${TARGET}" ]; then
            # Trong volume da co ban khac -> giu lai ban cu, doi ten ban ngoai.
            log "Da co ${TARGET}; luu ban ngoai thanh ${LINK}.bak"
            mv -f "${LINK}" "${LINK}.bak"
        else
            log "Chuyen ${LINK} vao volume: ${TARGET}"
            mv -f "${LINK}" "${TARGET}"
        fi
    fi

    # Truong hop 2: trong volume chua co gi -> tao file JSON rong.
    if [ ! -e "${TARGET}" ]; then
        log "Tao moi ${TARGET}"
        printf '%s\n' '{}' > "${TARGET}"
    fi
    chmod 600 "${TARGET}"

    # Truong hop 3: tao / sua symlink ~/.claude.json -> volume
    if [ -L "${LINK}" ]; then
        current="$(readlink "${LINK}")"
        if [ "${current}" != "${TARGET}" ]; then
            log "Symlink dang tro sai (${current}), tro lai ve ${TARGET}"
            ln -sfn "${TARGET}" "${LINK}"
        fi
    elif [ ! -e "${LINK}" ]; then
        log "Tao symlink ${LINK} -> ${TARGET}"
        ln -sfn "${TARGET}" "${LINK}"
    fi

    # Thu muc lam viec mac dinh (bind mount ./workspace tren host).
    mkdir -p "${HOME}/workspace" 2>/dev/null || true

    log "Xong. CLAUDE_CONFIG_DIR=${CFG_DIR}"
}

# "|| true" o day la CO Y: neu buoc nao that bai (vi du volume chua san sang),
# container van phai khoi dong duoc de nguoi dung con vao sua duoc.
main || log "CANH BAO: hook ket thuc voi loi - bo qua, van cho container khoi dong."

exit 0
