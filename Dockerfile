# =============================================================================
#  Image: Claude Code chay ben trong code-server (VS Code tren web)
#  Base:  codercom/code-server:4.134.0-bookworm
#         - Debian bookworm, user "coder" uid/gid 1000, HOME=/home/coder
#         - Lang nghe port 8080, co san curl / git / sudo (NOPASSWD) / dumb-init
#         - ENTRYPOINT san co: ["/usr/bin/entrypoint.sh","--bind-addr","0.0.0.0:8080","."]
#           => KHONG override ENTRYPOINT, chi tan dung hook entrypoint.d
# =============================================================================
FROM codercom/code-server:4.134.0-bookworm

# -----------------------------------------------------------------------------
#  GIAI DOAN 1 (root): cai goi he thong + Node.js
# -----------------------------------------------------------------------------
USER root

ARG DEBIAN_FRONTEND=noninteractive
# Node 22 la BAT BUOC: @anthropic-ai/claude-code khai bao engines.node >= 22.0.0
# (tu ban 2.1.198 tro di). Node 20 se bi canh bao EBADENGINE.
ARG NODE_VERSION=22.23.2

ENV TZ=Asia/Ho_Chi_Minh \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Cac goi bo sung. curl / git / wget / sudo / ca-certificates da co san trong base,
# van liet ke ca-certificates de chac chan chung chi TLS moi nhat.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ripgrep \
        python3 \
        python3-pip \
        python3-venv \
        tzdata \
        unzip \
        jq \
        less \
        gnupg \
        xz-utils; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    dpkg-reconfigure -f noninteractive tzdata; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# --- Node.js tu tarball chinh chu nodejs.org (KHONG dung NodeSource) ---------
# Ly do: kho NodeSource "nodistro" moi ho tro toi Debian 12; base image code-server
# dang dan chuyen sang Debian 13. Tarball chinh chu khong phu thuoc distro va
# cho phep kiem tra toan ven bang SHA256.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) node_arch='x64' ;; \
        arm64) node_arch='arm64' ;; \
        *) echo "Kien truc khong duoc ho tro: $arch" >&2; exit 1 ;; \
    esac; \
    tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${tarball}" -C /usr/local --strip-components=1 \
        --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md; \
    rm -f "${tarball}" SHASUMS256.txt; \
    node --version; \
    npm --version

# --- Tao san cac thu muc se duoc mount volume -------------------------------
# QUAN TRONG: Docker khoi tao named volume RONG bang cach copy noi dung VA quyen
# so huu tu thu muc tuong ung trong image. Neu thu muc thuoc root thi volume cung
# thuoc root => code-server / claude khong ghi duoc.
RUN set -eux; \
    mkdir -p \
        /home/coder/.claude \
        /home/coder/.config \
        /home/coder/workspace \
        /home/coder/entrypoint.d \
        /home/coder/.npm-global; \
    chown -R coder:coder \
        /home/coder/.claude \
        /home/coder/.config \
        /home/coder/workspace \
        /home/coder/entrypoint.d \
        /home/coder/.npm-global

# Script hook chay moi lan container khoi dong (do entrypoint.sh cua base goi)
COPY --chown=coder:coder docker/entrypoint.d/ /home/coder/entrypoint.d/
RUN chmod +x /home/coder/entrypoint.d/*.sh

# -----------------------------------------------------------------------------
#  GIAI DOAN 2 (coder): cai Claude Code vao npm prefix cua user
# -----------------------------------------------------------------------------
USER coder

# NPM_CONFIG_PREFIX tro vao HOME => sau nay co the chay
#   npm i -g @anthropic-ai/claude-code@latest   hoac   claude update
# ngay trong container ma KHONG can sudo.
ENV NPM_CONFIG_PREFIX=/home/coder/.npm-global \
    PATH=/home/coder/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    CLAUDE_CONFIG_DIR=/home/coder/.claude
# BUG CUA BASE IMAGE: base khai bao ENV ENTRYPOINTD=${HOME}/entrypoint.d trong khi
# HOME chua duoc set bang ENV => gia tri thuc te bi thanh "/entrypoint.d".
# Phai set lai tuong minh, neu khong hook duoi day se khong bao gio chay.
ENV ENTRYPOINTD=/home/coder/entrypoint.d

# Phien ban Claude Code. Dat "latest" de lay ban moi nhat, hoac ghim mot so
# cu the qua bien CLAUDE_CODE_VERSION trong .env khi ban moi nhat bi loi.
ARG CLAUDE_CODE_VERSION=latest

# Chi kiem tra bang "claude --version": no khong can TTY, khong can mang,
# khong can dang nhap. KHONG dung "claude --help" lam phep thu - lenh do co the
# day noi dung qua trinh phan trang va treo vo han khi build (khong co TTY).
# Luu y: KHONG them --omit=optional, vi binary native duoc phat hanh qua
# optionalDependencies + postinstall.
RUN set -eux; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    claude --version

# Terminal cua code-server mo bash dang LOGIN SHELL => no nap /etc/profile,
# ma file do GHI DE PATH bang gia tri mac dinh cua Debian, lam mat
# /home/coder/.npm-global/bin (ENV PATH o tren chi co tac dung voi tien trinh
# chinh cua container, khong song sot qua /etc/profile).
# => Ghi vao ca .bashrc (shell tuong tac) lan .profile (login shell).
RUN set -eux; \
    line='export PATH=/home/coder/.npm-global/bin:$PATH'; \
    printf '%s\n' "$line" >> /home/coder/.bashrc; \
    printf '%s\n' "$line" >> /home/coder/.profile

# Mo san thu muc lam viec (dau "." trong ENTRYPOINT cua base = WORKDIR nay)
WORKDIR /home/coder/workspace

EXPOSE 8080

# code-server co endpoint /healthz KHONG yeu cau xac thuc
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

# ENTRYPOINT / CMD ke thua nguyen tu base image.
