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
# tmux: cho phien Claude Code SONG SOT khi dong tab trinh duyet / mat mang /
#       khoa dien thoai. De chung o layer apt DAU TIEN nay de tan dung cache -
#       KHONG dat sau layer texlive-full (~5.5GB) keo build lai layer nang.
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
        xz-utils \
        tmux; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    dpkg-reconfigure -f noninteractive tzdata; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
#  TEXLIVE FULL  (~5.5 GB sau khi cai - day la layer NANG NHAT cua image)
#
#  De rieng mot layer: noi dung gan nhu khong bao gio doi, nen Docker cache lai
#  va cac lan build sau khong phai tai lai. DUNG gop chung voi layer khac.
#
#  texlive-full da bao gom texlive-lang-other (ho tro tieng Viet) va toan bo
#  package cua CTAN. Cac goi them vao duoi day KHONG nam trong texlive-full:
#    - latexmk        : bien dich tu dong, tu chay lai du so lan
#    - ghostscript    : nen PDF, chuyen doi PS/PDF
#    - poppler-utils  : pdftoppm / pdftotext / pdfinfo (PDF -> anh, trich text)
#    - fonts-liberation: font thay the Times/Arial/Courier dung metric
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        texlive-full \
        latexmk \
        ghostscript \
        poppler-utils \
        fonts-liberation \
        fonts-lmodern; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # Kiem tra ngay tai day de build FAIL SOM neu cai hong
    xelatex --version | head -n 1; \
    latexmk --version

# -----------------------------------------------------------------------------
#  CONG CU VIDEO / AM THANH
#    - ffmpeg      : cat, ghep, chuyen ma, trich khung hinh, chen phu de
#    - imagemagick : xu ly anh hang loat (convert / mogrify)
#    - mkvtoolnix  : ghep-tach track trong file .mkv (mkvmerge)
#    - atomicparsley: nhung thumbnail vao file mp4/m4a
#    - yt-dlp      : tai video (cai o layer duoi, khong lay tu apt)
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        imagemagick \
        mkvtoolnix \
        atomicparsley; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    ffmpeg -version | head -n 1

# --- yt-dlp ------------------------------------------------------------------
# KHONG dung "apt install yt-dlp": ban trong kho Debian cu hang thang, ma YouTube
# doi co che lien tuc => ban cu hong rat nhanh.
# KHONG dung "pip install": Debian bookworm bat PEP 668 (externally-managed),
# pip cai vao he thong se bi tu choi.
# => Tai zipapp chinh chu. File nay chi can python3 (da co o layer tren) nen
#    chay duoc tren ca amd64 lan arm64, khong phu thuoc kien truc.
ARG YTDLP_VERSION=latest
RUN set -eux; \
    if [ "${YTDLP_VERSION}" = "latest" ]; then \
        url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"; \
    else \
        url="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp"; \
    fi; \
    curl -fsSL "$url" -o /usr/local/bin/yt-dlp; \
    chmod 755 /usr/local/bin/yt-dlp; \
    yt-dlp --version

# -----------------------------------------------------------------------------
#  CONG CU OFFICE - phan he thong (~1 GB)
#    - pandoc      : chuyen doi Markdown <-> docx / pptx / pdf. Cong cu chinh
#                    de bien noi dung soan bang Markdown thanh file Word.
#    - libreoffice : chay headless de chuyen doi va sua file Office bang lenh
#                    (docx -> pdf, xlsx -> csv, pptx -> pdf...). Chi cai 3 module
#                    Writer / Calc / Impress, KHONG cai ban full (tiet kiem ~1 GB).
#    - default-jre-headless: mot so tinh nang cua LibreOffice (macro, bo loc
#                    nang cao) can Java. Thieu no thi convert co ban van chay
#                    nhung se in canh bao va mot so dinh dang bi loi.
#    - fonts-dejavu: phu day du tieng Viet, dung lam font du phong khi tai lieu
#                    goi font khong co trong container.
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        pandoc \
        libreoffice-writer \
        libreoffice-calc \
        libreoffice-impress \
        default-jre-headless \
        fonts-dejavu; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    pandoc --version | head -n 1; \
    soffice --version

# -----------------------------------------------------------------------------
#  CONG CU OFFICE - phan thu vien Python (~300 MB)
#
#  Debian bookworm bat PEP 668 (externally-managed): "pip install" thang vao
#  python he thong se bi TU CHOI. Cach xu ly o day la tao mot venv rieng va
#  dat no LEN DAU PATH => lenh "python3" / "pip" mac dinh tro toi venv nay.
#
#  Dung co --system-site-packages de venv VAN NHIN THAY cac goi python3-* cai
#  bang apt. Nho vay khong mat gi, chi them.
# -----------------------------------------------------------------------------
RUN set -eux; \
    python3 -m venv --system-site-packages /opt/venv; \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip; \
    /opt/venv/bin/pip install --no-cache-dir \
        python-docx \
        python-pptx \
        openpyxl \
        XlsxWriter \
        docxtpl \
        odfpy \
        Pillow \
        lxml; \
    chmod -R a+rX /opt/venv; \
    /opt/venv/bin/python -c "import docx, pptx, openpyxl, xlsxwriter, docxtpl; print('office libs OK')"

# -----------------------------------------------------------------------------
#  PHAN TICH DU LIEU + DASHBOARD (~1.5 GB)
#
#  De rieng layer voi phan Office: nhom nay nang hon va thay doi thuong xuyen
#  hon, tach ra thi sua ben nay khong phai cai lai ben kia.
#
#    pandas / numpy / scipy      : nen tang xu ly so lieu
#    scikit-learn / statsmodels  : hoi quy, phan cum, kiem dinh thong ke
#    matplotlib / seaborn        : bieu do tinh, xuat PNG de chen vao docx/PDF
#    plotly                      : bieu do tuong tac (zoom, hover)
#    kaleido                     : xuat bieu do plotly ra PNG/SVG/PDF - BAT BUOC
#                                  neu muon nhung bieu do plotly vao file Word
#    streamlit                   : dung dashboard bang Python thuan, khong can
#                                  biet HTML/CSS/JS
#    pyarrow                     : streamlit va pandas dung de doc/ghi nhanh
#    tabulate                    : in bang dep ra terminal / Markdown
#
#  Font tieng Viet: matplotlib mac dinh dung DejaVu Sans - da cai o layer Office
#  nen bieu do co dau tieng Viet hien dung, khong bi o vuong.
# -----------------------------------------------------------------------------
RUN set -eux; \
    /opt/venv/bin/pip install --no-cache-dir \
        pandas \
        numpy \
        scipy \
        scikit-learn \
        statsmodels \
        matplotlib \
        seaborn \
        plotly \
        kaleido \
        streamlit \
        pyarrow \
        tabulate; \
    chmod -R a+rX /opt/venv; \
    MPLBACKEND=Agg /opt/venv/bin/python -c "\
import pandas, numpy, scipy, sklearn, statsmodels, matplotlib, seaborn, plotly, streamlit; \
print('data libs OK')"

# Dat venv len dau PATH cho MOI user (ke ca root o cac layer sau).
ENV PATH=/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

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

# Script hook chay moi lan container khoi dong (do entrypoint.sh cua base goi).
# Glob *.sh phia duoi phu ca file moi them (20-tmux-session.sh).
COPY --chown=coder:coder docker/entrypoint.d/ /home/coder/entrypoint.d/
RUN chmod +x /home/coder/entrypoint.d/*.sh

# Cau hinh tmux cho user coder: mouse mode (dung tren dien thoai), scrollback
# lon, status bar. Xem docker/tmux.conf.
COPY --chown=coder:coder docker/tmux.conf /home/coder/.tmux.conf

# Lenh tien loi `cc`: vao (hoac tao) phien tmux "claude" ben buong. Dat vao
# /usr/local/bin (da nam trong PATH mac dinh cua moi shell).
COPY docker/bin/cc /usr/local/bin/cc
RUN chmod 755 /usr/local/bin/cc

# -----------------------------------------------------------------------------
#  GIAI DOAN 2 (coder): cai Claude Code vao npm prefix cua user
# -----------------------------------------------------------------------------
USER coder

# NPM_CONFIG_PREFIX tro vao HOME => sau nay co the chay
#   npm i -g @anthropic-ai/claude-code@latest   hoac   claude update
# ngay trong container ma KHONG can sudo.
# MPLBACKEND=Agg: container khong co man hinh, ep matplotlib ve backend khong
# giao dien - neu khong, plt.show() se bao loi thieu display.
ENV NPM_CONFIG_PREFIX=/home/coder/.npm-global \
    PATH=/home/coder/.npm-global/bin:/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    CLAUDE_CONFIG_DIR=/home/coder/.claude \
    MPLBACKEND=Agg
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
    line='export PATH=/home/coder/.npm-global/bin:/opt/venv/bin:$PATH'; \
    printf '%s\n' "$line" >> /home/coder/.bashrc; \
    printf '%s\n' "$line" >> /home/coder/.profile

# Mo san thu muc lam viec (dau "." trong ENTRYPOINT cua base = WORKDIR nay)
WORKDIR /home/coder/workspace

EXPOSE 8080

# code-server co endpoint /healthz KHONG yeu cau xac thuc
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

# ENTRYPOINT / CMD ke thua nguyen tu base image.
