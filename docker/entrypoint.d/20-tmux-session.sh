#!/bin/sh
# =============================================================================
#  Hook khoi dong container - do /usr/bin/entrypoint.sh cua base image goi.
#
#  MUC DICH: tao san mot phien tmux "claude" o che do detached ngay khi
#  container start. Nho vay du container restart, nguoi dung chi can go `cc`
#  (hoac `tmux attach -t claude`) trong terminal la co ngay phien de dung.
#
#  Dac tinh: POSIX sh, chay lai nhieu lan van an toan (idempotent), va MOI loi
#  deu bi nuot (|| true) de KHONG BAO GIO chan container khoi dong - tmux hong
#  thi cung khong duoc lam sap ca code-server.
# =============================================================================
set -eu

SESSION="claude"

log() {
    echo "[20-tmux-session] $*"
}

main() {
    # tmux chua cai (vi du build cu) -> bo qua yen lang, khong lam gi.
    if ! command -v tmux >/dev/null 2>&1; then
        log "Khong co tmux - bo qua tao phien."
        return 0
    fi

    # Bao dam PATH thay duoc `claude` khi phien tmux tu chay no.
    export PATH="/home/coder/.npm-global/bin:/opt/venv/bin:${PATH}"

    # Da co phien roi -> khong tao lai (idempotent, an toan khi restart).
    if tmux has-session -t "${SESSION}" 2>/dev/null; then
        log "Phien tmux '${SESSION}' da ton tai - giu nguyen."
        return 0
    fi

    # Tao phien detached. KHONG tu chay `claude` o day: lan dau container start
    # nguoi dung chua dang nhap, chay claude ngay se hien man dang nhap trong
    # phien nen ma khong ai thay. De phien mo mot shell trong; khi nguoi dung
    # go `cc` va attach vao ho tu chay claude (hoac dung cua so trong nay).
    # -n main: dat ten cua so co dinh cho de nhan ra tren status bar va de
    # tham chieu (vi du "claude:main") thay vi ten mac dinh doi theo lenh dang chay.
    log "Tao phien tmux detached '${SESSION}' tai ${HOME}/workspace"
    tmux new-session -d -s "${SESSION}" -n main -c "${HOME}/workspace"
    log "Xong. Vao phien bang lenh: cc"
}

# "|| true" o day la CO Y: neu tao phien that bai, container van phai khoi dong
# duoc de nguoi dung con vao sua duoc.
main || log "CANH BAO: hook ket thuc voi loi - bo qua, van cho container khoi dong."

exit 0
