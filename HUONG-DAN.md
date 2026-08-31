# Hướng dẫn triển khai Claude Code lên VPS có tên miền riêng

> Mở `https://code.tenmien.com` → nhập mật khẩu → có ngay VS Code trên trình duyệt →
> mở terminal gõ `claude` là dùng được Claude Code. Đăng nhập một lần, dùng mãi.

Tài liệu này viết cho người **chưa từng dùng Docker hay Traefik**. Mọi lệnh đều copy-paste chạy được.

> 🚨 **Điều kiện tiên quyết quan trọng:** stack này **không tự chạy Traefik**. Nó giả định
> trên VPS **đã có sẵn một Traefik đang chạy** (trong tài liệu này là stack ở
> `/home/N8N/traefik-stack`) và chỉ gắn nhãn để Traefik đó tự tạo route. Xem
> [mục 0](#0-kiến-trúc-hệ-thống) để biết chính xác cần những gì.

---

## Mục lục

- [0. Kiến trúc hệ thống](#0-kiến-trúc-hệ-thống)
- [1. Chuẩn bị](#1-chuẩn-bị)
- [2. Triển khai từng bước](#2-triển-khai-từng-bước)
- [3. Đăng nhập Claude Code lần đầu](#3-đăng-nhập-claude-code-lần-đầu)
- [4. Giải thích từng file cấu hình](#4-giải-thích-từng-file-cấu-hình)
- [5. Vận hành hằng ngày](#5-vận-hành-hằng-ngày)
- [6. Xử lý sự cố](#6-xử-lý-sự-cố)
- [7. Ghi chú bảo mật](#7-ghi-chú-bảo-mật)
- [8. Bảng biến môi trường `.env`](#8-bảng-biến-môi-trường-env)
- [Phụ lục A — Dùng `ANTHROPIC_API_KEY` thay cho tài khoản Pro/Max](#phụ-lục-a--dùng-anthropic_api_key-thay-cho-tài-khoản-promax)
- [Phụ lục B — Đăng nhập không cần trình duyệt (`claude setup-token`)](#phụ-lục-b--đăng-nhập-không-cần-trình-duyệt-claude-setup-token)
- [Phụ lục C — Đổi `workspace` sang named volume](#phụ-lục-c--đổi-workspace-sang-named-volume)
- [Phụ lục D — Bật thêm middleware bảo mật (tuỳ chọn)](#phụ-lục-d--bật-thêm-middleware-bảo-mật-tuỳ-chọn)

---

## 0. Kiến trúc hệ thống

```
                       Internet
                          |
                          | HTTPS :443  (HTTP :80 tự chuyển hướng sang 443)
                          v
    ==========================================================
     STACK KHÁC — /home/N8N/traefik-stack   (KHÔNG thuộc repo này)
    ==========================================================
              +-------------------------+
              |   Container: traefik    |   đã chạy sẵn từ trước
              |-------------------------|
              | - Giữ cổng 80 và 443    |   entryPoints: web / websecure
              | - Kết thúc TLS          |   certresolver "letsencrypt"
              | - Đọc nhãn Docker của   |   providers.docker
              |   các container khác    |   exposedByDefault: false
              +-----------+-------------+
                          |
                          | mạng Docker dùng chung "traefik-net"
                          | HTTP :8080  (KHÔNG lộ ra Internet)
                          v
    ==========================================================
     STACK NÀY — ~/claude-vps
    ==========================================================
              +-------------------------+
              |  Container: claude-code |   build từ Dockerfile
              |-------------------------|
              | BasicAuth (lớp 1)       |   middleware khai bằng NHÃN
              |   claude-auth@docker    |   ngay trong compose của stack này
              | code-server 4.134.0     |   VS Code trên web
              |   + mật khẩu (lớp 2)    |
              | Node.js 22.23.2         |
              | @anthropic-ai/claude-code|
              +-----------+-------------+
                          |
        +-----------------+------------------+
        |                 |                  |
  claude_config      code_config        ./workspace
  (named volume)    (named volume)      (bind mount ra host)
  TOKEN ĐĂNG NHẬP   cài đặt + extension  MÃ NGUỒN CỦA BẠN
```

**Vì sao không tự chạy Traefik riêng?** Vì **hai Traefik không thể cùng bind cổng 80/443**
trên một máy. VPS đã có sẵn một Traefik giữ hai cổng đó rồi, nên stack này chỉ việc nối vào
mạng chung và gắn nhãn — Traefik có sẵn sẽ tự phát hiện và tạo route.

### 0.1. Điều kiện tiên quyết — Traefik có sẵn phải đáp ứng đúng những thứ này

| Hạng mục | Giá trị bắt buộc | Dùng ở đâu trong stack này |
|---|---|---|
| Docker network | `traefik-net` | `networks.web.name` + nhãn `traefik.docker.network` |
| entryPoint HTTPS | `websecure` (:443) | nhãn `...routers.claude.entrypoints=websecure` |
| entryPoint HTTP | `web` (:80, tự redirect sang `websecure`) | dùng cho HTTP-01 challenge của Let's Encrypt |
| certificatesResolver | tên là `letsencrypt`, `httpChallenge` qua entrypoint `web` | nhãn `...routers.claude.tls.certresolver=letsencrypt` |
| `providers.docker` | `exposedByDefault: false`, `network: traefik-net` | vì thế bắt buộc phải có nhãn `traefik.enable=true` |
| Kho chứng chỉ | `/letsencrypt/acme.json` — **thuộc stack Traefik** | stack này **không** đụng tới |
| `providers.file` | `filename: /etc/traefik/config/dynamic.yml` | xem cảnh báo ngay dưới |

> ### 🚨 Lưu ý quan trọng về `providers.file`
>
> Traefik có sẵn khai báo `providers.file.filename` — trỏ tới **đúng một file**
> `dynamic.yml`, **không phải một thư mục**. Nghĩa là **thả thêm file `.yml` khác vào thư
> mục `config/` sẽ KHÔNG được nạp**. Muốn thêm middleware kiểu `@file` thì phải **nối nội
> dung vào chính `dynamic.yml`** — xem
> [Phụ lục D](#phụ-lục-d--bật-thêm-middleware-bảo-mật-tuỳ-chọn).

Kiểm tra nhanh trên VPS xem điều kiện tiên quyết đã đủ chưa:

```bash
docker ps --filter name=traefik                  # container traefik có đang chạy không?
docker network inspect traefik-net >/dev/null && echo "network OK"
docker logs --tail 30 traefik                    # log có sạch không?
```

Nếu network `traefik-net` chưa tồn tại thì `docker compose up -d` của stack này sẽ báo
lỗi ngay (`network traefik-net declared as external, but could not be found`) — đó là
hành vi đúng, đừng tự tạo network rỗng bằng tay, hãy khởi động stack Traefik trước.

> Traefik có sẵn **đã bật dashboard** tại `traefik.<tên-miền>` với BasicAuth riêng
> (middleware `dashboard-auth` của stack Traefik). Bạn **không cần** làm gì thêm trong repo này.

### 0.2. Hai lớp mật khẩu — cố ý làm vậy

| Lớp | Ai kiểm tra | Biến trong `.env` | Chặn được gì |
|---|---|---|---|
| 1 | Traefik (BasicAuth, middleware `claude-auth@docker` khai bằng nhãn của stack này) | `BASIC_AUTH_USER` / `BASIC_AUTH_HASH` | Bot quét cổng không bao giờ chạm được tới code-server |
| 2 | code-server | `CODE_SERVER_PASSWORD` | Phòng khi lớp 1 bị cấu hình sai |

### 0.3. Dữ liệu nằm ở đâu

| Dữ liệu | Vị trí | Mất khi nào |
|---|---|---|
| Token đăng nhập Claude | named volume `claude_config` | Chỉ khi chạy `docker compose down -v` |
| Cài đặt / extension VS Code | named volume `code_config` | Chỉ khi chạy `docker compose down -v` |
| Mã nguồn của bạn | thư mục `./workspace` trên VPS | Chỉ khi bạn tự xoá |
| Chứng chỉ HTTPS | `acme.json` của **stack Traefik** (`/home/N8N/traefik-stack`) | Không thuộc phạm vi stack này — sao lưu ở stack Traefik |

---

## 1. Chuẩn bị

### 1.1. VPS

| Hạng mục | Tối thiểu | **Khuyến nghị** |
|---|---|---|
| RAM | 2 GB + 2 GB swap | **4 GB** |
| CPU | 1 vCPU | **2 vCPU** |
| Ổ cứng | 20 GB SSD | **40 GB SSD** |
| Hệ điều hành | Ubuntu 22.04 / Debian 12 | **Ubuntu 24.04 LTS** |
| Kiến trúc | x86_64 hoặc ARM64 | cả hai đều chạy được |

> Tài liệu chính thức của Claude Code yêu cầu **tối thiểu 4 GB RAM**. Dưới mức đó vẫn
> chạy được nhưng dễ bị OOM (container bị kernel giết) khi Claude xử lý repo lớn.

Nếu VPS chỉ có 2 GB, thêm swap trước khi làm gì khác:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

### 1.2. Tên miền và bản ghi DNS

Bạn cần một tên miền (hoặc tên miền con) trỏ về **IP public của VPS**.

Lấy IP public của VPS:

```bash
curl -s https://ifconfig.me; echo
```

Giả sử kết quả là `203.0.113.45` và bạn muốn dùng `code.example.com`. Vào trang quản lý
DNS của nhà cung cấp tên miền và tạo bản ghi:

| Type | Name (Host) | Value (Points to) | TTL | Proxy |
|---|---|---|---|---|
| `A` | `code` | `203.0.113.45` | `300` (5 phút) | **DNS only / TẮT** |

Chú thích:

- **Name** ghi là `code` (không phải `code.example.com`) — hầu hết nhà cung cấp tự ghép
  phần đuôi. Nếu muốn dùng thẳng tên miền gốc `example.com` thì ghi `@`.
- **Nếu dùng Cloudflare**: bắt buộc để đám mây **màu xám (DNS only)**, không bật proxy
  (đám mây cam). Proxy của Cloudflare sẽ chặn HTTP-01 challenge của Let's Encrypt và làm
  WebSocket của code-server chập chờn.

Kiểm tra DNS đã lan truyền chưa (chờ 5–30 phút sau khi tạo):

```bash
getent hosts code.example.com
# hoặc
dig +short code.example.com
```

Kết quả phải đúng bằng IP VPS. **Chưa đúng thì đừng chạy tiếp** — Let's Encrypt sẽ từ chối
cấp chứng chỉ và bạn có nguy cơ chạm giới hạn 5 lần thất bại/giờ.

### 1.3. Mở tường lửa

Stack `claude-vps` **không publish cổng nào ra host** (service `claude-code` dùng `expose`
chứ không dùng `ports`). Hai cổng 80/443 là do **stack Traefik có sẵn** giữ — nếu Traefik đó
đang chạy được thì tường lửa nhiều khả năng đã mở sẵn rồi. Kiểm tra lại cho chắc:

```bash
sudo ss -lntp | grep -E ':80|:443'   # phải thấy tiến trình docker-proxy / traefik
sudo ufw status verbose
```

Nếu chưa mở:

```bash
sudo ufw allow 22/tcp     # SSH - mở TRƯỚC, nếu không sẽ tự khoá mình ra ngoài
sudo ufw allow 80/tcp     # HTTP - Let's Encrypt cần cổng này cho httpChallenge
sudo ufw allow 443/tcp    # HTTPS
sudo ufw enable
sudo ufw status verbose
```

> Ngoài `ufw`, nhiều nhà cung cấp (AWS, GCP, Azure, Vultr, DigitalOcean) còn có **firewall
> riêng ở tầng hạ tầng**. Nhớ mở 80/443 ở đó nữa, nếu không sẽ "mở rồi mà vẫn không vào được".
>
> ⚠️ **Đừng đóng cổng 80.** Certresolver `letsencrypt` của Traefik có sẵn dùng `httpChallenge`
> qua entrypoint `web` (:80). Đóng cổng 80 = không xin được chứng chỉ, dù bạn chỉ dùng HTTPS.

### 1.4. Tài khoản Claude

Cần một tài khoản **Claude Pro hoặc Max** (đăng nhập được tại claude.ai). Stack này mặc
định dùng đăng nhập OAuth bằng tài khoản thuê bao, **không** dùng API key trả tiền theo
token. Nếu muốn dùng API key, xem [Phụ lục A](#phụ-lục-a--dùng-anthropic_api_key-thay-cho-tài-khoản-promax).

---

## 2. Triển khai từng bước

### Bước 1 — Đưa mã nguồn lên VPS

**Cách A — dùng git (khuyến nghị):**

```bash
# Trên máy Windows, TRƯỚC khi commit, để git không tự đổi LF thành CRLF:
git config --global core.autocrlf input

# Trên VPS:
cd ~
git clone <url-repo-cua-ban> claude-vps
cd claude-vps
```

**Cách B — copy trực tiếp từ Windows bằng scp:**

```powershell
# Chạy trên PowerShell của máy Windows
scp -r D:\MYDOCUMENT_2027\LAPTRINH\claude-vps user@203.0.113.45:~/
```

### Bước 2 — Xử lý ký tự xuống dòng (chỉ khi soạn/sửa file trên Windows)

Windows kết thúc dòng bằng `CRLF` (`\r\n`), Linux dùng `LF` (`\n`). Một script `.sh` có
`CRLF` sẽ báo lỗi khó hiểu kiểu:

```
/usr/bin/env: 'bash\r': No such file or directory
```

Kiểm tra và sửa trên VPS:

```bash
cd ~/claude-vps

# Kiểm tra: nếu KHÔNG in ra gì thì file đã đúng chuẩn LF
grep -rlU $'\r' . --exclude-dir=.git || echo "Tất cả file đã là LF - OK"

# Nếu có file dính CRLF, sửa bằng 1 trong 2 cách:
sudo apt-get install -y dos2unix
find . -type f \( -name '*.sh' -o -name 'Dockerfile' -o -name '*.yml' -o -name '*.template' \) \
     -exec dos2unix {} +

# Hoặc không cần cài gì thêm:
find . -type f \( -name '*.sh' -o -name 'Dockerfile' -o -name '*.yml' -o -name '*.template' \) \
     -exec sed -i 's/\r$//' {} +
```

> `scripts/setup.sh` cũng tự phát hiện và sửa CRLF ở bước 3, nhưng bản thân `setup.sh`
> phải đúng LF thì mới chạy được để làm việc đó — nên vẫn nên kiểm tra bằng tay trước.

### Bước 3 — Chạy setup lần thứ nhất (để tạo `.env`)

```bash
bash scripts/setup.sh
```

Lần chạy đầu tiên script sẽ **dừng lại** và báo: vừa tạo `.env` từ `.env.example`, hãy
điền giá trị bắt buộc. Đây là hành vi đúng, không phải lỗi.

### Bước 4 — Điền `.env`

```bash
nano .env
```

Sửa đúng **một dòng** này:

```dotenv
DOMAIN=code.example.com
```

Lưu lại (`Ctrl+O`, `Enter`, `Ctrl+X`).

> Không còn biến `ACME_EMAIL` nữa. Email đăng ký Let's Encrypt nằm trong cấu hình của
> **stack Traefik có sẵn**, không phải việc của stack này.

Những giá trị còn lại (`CODE_SERVER_PASSWORD`, `BASIC_AUTH_USER`, `BASIC_AUTH_HASH`) sẽ do
`setup.sh` sinh tự động ở bước sau — **không cần tự điền**.

### Bước 5 — Chạy setup lần thứ hai (triển khai thật)

```bash
bash scripts/setup.sh
```

Script làm tuần tự 9 việc:

| # | Việc |
|---|---|
| 1 | Kiểm tra hệ điều hành Linux, quyền sudo, các lệnh cơ bản |
| 2 | Cài Docker Engine + Compose plugin nếu chưa có |
| 3 | Chuẩn bị thư mục và quyền: tạo `workspace/` + `chown 1000:1000`, tạo `backups/`, tự sửa CRLF |
| 4 | Đọc và kiểm tra `.env` (bắt buộc có `DOMAIN` hợp lệ) |
| 5 | Sinh mật khẩu ngẫu nhiên + hash bcrypt, **tự escape `$` → `$$`** |
| 6 | **Tự kiểm chứng escaping** bằng `docker compose config` |
| 7 | Đối chiếu DNS với IP public, mở cổng ufw 80/443 |
| 8 | `docker compose up -d --build` rồi chờ container healthy |
| 9 | Gọi thử HTTPS: mong đợi `401` khi không có mật khẩu, `200/302` khi có |

> So với bản cũ, script **không còn** bước sinh `traefik/traefik.yml` và **không còn** tạo
> `acme.json` — cả hai việc đó giờ thuộc stack Traefik có sẵn.

Lần đầu build image mất khoảng **5–12 phút** (tải base image ~370 MB, cài Node, cài
Claude Code). Các lần sau nhanh hơn nhiều nhờ cache.

### Bước 6 — Lưu mật khẩu

Kết thúc, script in ra bảng như sau:

```
  Địa chỉ truy cập : https://code.example.com
  BasicAuth user   : admin
  BasicAuth pass   : xK7mQ2pR9wL4nT6vB8sD3fH5   <-- LƯU LẠI NGAY, không hiện lại lần sau
  code-server pass : jY3nW8qE5rT2uI7oP1aS4dF6   <-- màn hình đăng nhập thứ 2
```

**Chép ngay hai mật khẩu này vào trình quản lý mật khẩu.** Chúng vẫn nằm trong `.env` (dạng
plaintext với `CODE_SERVER_PASSWORD`, dạng hash với BasicAuth) nhưng mật khẩu BasicAuth
**không thể khôi phục từ hash** — mất là phải sinh lại bằng `bash scripts/setup.sh --regen-auth`.

### Bước 7 — Mở trình duyệt

Truy cập `https://code.example.com`:

1. Hiện hộp thoại đăng nhập của trình duyệt → nhập user/pass **BasicAuth**.
2. Hiện màn hình "Welcome to code-server" → nhập **code-server pass**.
3. Vào được VS Code, thư mục mở sẵn là `/home/coder/workspace`.

Nếu trình duyệt báo lỗi chứng chỉ, chờ thêm 1–2 phút rồi tải lại — Let's Encrypt cần
30–90 giây để cấp chứng chỉ lần đầu.

---

## 3. Đăng nhập Claude Code lần đầu

Đây là bước quan trọng nhất, làm **một lần duy nhất**.

### 3.1. Các bước

1. Trong VS Code trên web, mở terminal: menu **Terminal → New Terminal**, hoặc phím tắt
   `` Ctrl + ` ``.

2. Kiểm tra Claude Code đã cài đúng:

   ```bash
   claude --version
   node --version     # phải là v22.23.2
   ```

3. Khởi động:

   ```bash
   claude
   ```

4. Claude hỏi cách đăng nhập → chọn **"Claude account with subscription"** (tài khoản
   Pro/Max), **không** chọn Anthropic Console/API.

5. Terminal in ra một URL dài `https://claude.ai/oauth/authorize?...`. **Copy toàn bộ URL**
   (bôi đen rồi `Ctrl+Shift+C`) và dán vào trình duyệt trên **máy cá nhân** của bạn.

6. Đăng nhập tài khoản Claude và bấm **Authorize**.

7. ⚠️ **Điểm hay gây bối rối:** Trình duyệt sẽ **không tự quay lại** terminal, mà hiển thị
   một **đoạn mã**. Đây là hành vi hoàn toàn bình thường — tài liệu chính thức của Anthropic
   ghi rõ điều này xảy ra khi trình duyệt không thể kết nối tới callback server nội bộ của
   Claude Code, **thường gặp trong WSL2, phiên SSH và container**.

8. Copy đoạn mã đó, quay lại terminal của code-server, dán vào dòng nhắc:

   ```
   Paste code here if prompted >
   ```

   rồi bấm `Enter`.

9. Xong. Kiểm tra lại:

   ```bash
   claude
   # trong phiên chat, gõ:
   /status
   ```

### 3.2. Token được lưu ở đâu và có mất không?

```
/home/coder/.claude/.credentials.json    (quyền 0600)
     ^^^^^^^^^^^^^^^^^^^^^
     chính là named volume "claude_config"
```

Image đã set sẵn `CLAUDE_CONFIG_DIR=/home/coder/.claude`. Theo tài liệu chính thức, khi biến
này được set trên Linux thì file `.credentials.json` nằm trong thư mục đó — tức là nằm trong
volume, tách rời khỏi vòng đời của container.

| Lệnh | Có mất đăng nhập không? |
|---|---|
| `docker compose restart` | ❌ Không |
| `docker compose down` rồi `up -d` | ❌ Không |
| `docker compose up -d --build` (rebuild image) | ❌ Không |
| Khởi động lại VPS | ❌ Không |
| **`docker compose down -v`** | ✅ **CÓ — XOÁ SẠCH** |
| `docker volume rm claude_config` | ✅ **CÓ — XOÁ SẠCH** |

> ### 🚨 CẢNH BÁO
>
> **Cờ `-v` trong `docker compose down -v` sẽ XOÁ VĨNH VIỄN cả `claude_config` lẫn
> `code_config`.** Bạn sẽ mất token đăng nhập Claude và toàn bộ extension/cài đặt VS Code.
> Mã nguồn trong `./workspace` thì an toàn (bind mount, nằm trên host).
>
> **Không bao giờ gõ `-v` trừ khi bạn cố ý muốn xoá sạch.**

Ngoài `.credentials.json`, Claude Code còn dùng file `~/.claude.json` (lưu phiên đăng nhập,
cấu hình MCP, danh sách project đã tin tưởng). Tài liệu **không khẳng định rõ** file này có
đi theo `CLAUDE_CONFIG_DIR` hay không, nên stack này có thêm một lớp bảo hiểm:
`docker/entrypoint.d/10-claude-config.sh` tự chuyển file đó vào volume và tạo symlink trỏ về.
Kiểm tra bằng:

```bash
docker compose exec claude-code ls -la /home/coder/.claude.json
# kết quả mong đợi:
# lrwxrwxrwx ... /home/coder/.claude.json -> /home/coder/.claude/.claude.json
```

---

## 4. Giải thích từng file cấu hình

```
claude-vps/
├── Dockerfile                          Công thức tạo image code-server + Claude Code
├── docker-compose.yml                  Khai báo 1 container, mạng ngoài, volume, nhãn Traefik
├── .env                                (BẠN TẠO) bí mật — KHÔNG commit
├── .env.example                        Mẫu để copy thành .env
├── .gitignore                          Chặn commit nhầm .env / workspace / backups
├── .gitattributes                      Ép LF, chống lỗi CRLF khi soạn trên Windows
├── docker/entrypoint.d/
│   └── 10-claude-config.sh             Hook chạy mỗi lần container khởi động
├── scripts/
│   ├── setup.sh                        Cài đặt + triển khai + tự kiểm chứng
│   └── backup.sh                       Sao lưu volume + workspace + cấu hình
├── workspace/                          MÃ NGUỒN CỦA BẠN (bind mount)
├── backups/                            (SINH RA) các file .tar.gz sao lưu
└── HUONG-DAN.md                        File này
```

> **Không còn thư mục `traefik/`.** Trước đây repo này có `traefik/traefik.yml.template`,
> `traefik/acme.json` và `traefik/dynamic/middlewares.yml` để tự chạy một Traefik riêng.
> Toàn bộ đã bị xoá vì stack dùng chung Traefik có sẵn của VPS. Cấu hình Traefik giờ nằm ở
> `/home/N8N/traefik-stack`, sửa ở đó chứ không sửa trong repo này.

### 4.1. `Dockerfile`

| Dòng / khối | Có nên sửa? | Giải thích |
|---|---|---|
| `FROM codercom/code-server:4.134.0-bookworm` | ✅ Sửa được | Đổi tag để nâng cấp code-server. Xem tag mới tại Docker Hub. Luôn ghim phiên bản cụ thể, **đừng dùng `:latest`**. |
| `ARG NODE_VERSION=22.23.2` | ⚠️ Cẩn thận | Chỉ đổi sang bản Node **≥ 22**. Gói `@anthropic-ai/claude-code` khai báo `engines.node >= 22.0.0`; Node 20 sẽ cảnh báo `EBADENGINE` và có thể hỏng. |
| `ENV TZ=Asia/Ho_Chi_Minh` | ✅ Sửa được | Múi giờ. |
| Khối `apt-get install` | ✅ Thêm được | Muốn thêm Go, Rust, PHP... thì thêm vào đây rồi rebuild. |
| Khối tải Node từ `nodejs.org` | ❌ Đừng đụng | Dùng tarball chính chủ + verify SHA256 thay vì kho NodeSource, vì NodeSource mới hỗ trợ tới Debian 12 còn base image đang chuyển sang Debian 13. |
| `mkdir -p` + `chown coder:coder` | ❌ **Tuyệt đối đừng xoá** | Docker khởi tạo named volume rỗng bằng cách sao chép nội dung **và quyền sở hữu** từ thư mục tương ứng trong image. Xoá dòng này → volume thuộc `root` → code-server không ghi được gì. |
| `ENV ENTRYPOINTD=/home/coder/entrypoint.d` | ❌ **Đừng xoá** | Base image có lỗi: nó khai báo `ENV ENTRYPOINTD=${HOME}/entrypoint.d` trong khi `HOME` chưa được set bằng `ENV`, nên giá trị thật bị thành `/entrypoint.d`. Không set lại thì hook không bao giờ chạy. |
| `ENV NPM_CONFIG_PREFIX=/home/coder/.npm-global` | ❌ Đừng đụng | Nhờ nó mà bạn chạy được `npm i -g @anthropic-ai/claude-code@latest` trong container mà không cần `sudo`. |
| `RUN npm install -g ... && claude --version` | ❌ Đừng đụng | `claude --version` cố tình đặt ở đây để build **fail sớm** nếu gói cài hỏng. |
| `HEALTHCHECK ... /healthz` | ✅ Sửa được | code-server có endpoint `/healthz` không cần xác thực. |
| Không có `ENTRYPOINT` | ❌ Đừng thêm | Kế thừa từ base image. Ghi đè sẽ làm hỏng `fixuid` và hook `entrypoint.d`. |

### 4.2. `docker-compose.yml`

File này khai báo **đúng một service** (`claude-code`). Không có service `traefik`.

**Khối `networks`**

```yaml
networks:
  web:
    name: traefik-net
    external: true
```

| Khoá | Ý nghĩa |
|---|---|
| `name: traefik-net` | Tên network **thật** trên Docker — phải trùng đúng network mà Traefik có sẵn đang dùng (`providers.docker.network`). |
| `external: true` | "Network này do người khác tạo, đừng tự tạo." Compose sẽ **không** tạo mới và **không** xoá khi `down`. Nếu network chưa tồn tại, `up` sẽ báo lỗi ngay thay vì âm thầm tạo một network rỗng không ai route tới. |

> 🚨 Nếu đổi tên network ở đây thì **phải đổi luôn** nhãn `traefik.docker.network` bên dưới.
> Hai giá trị lệch nhau là Traefik sẽ route sang IP sai và bạn nhận `502`.

**Khối `volumes`**

```yaml
volumes:
  claude_config:
    name: claude_config
  code_config:
    name: code_config
```

Tên cố định giúp `scripts/backup.sh` tìm đúng volume mà không phụ thuộc tên project.

**Service `claude-code`**

| Dòng | Ý nghĩa |
|---|---|
| `expose: 8080` | **Không phải `ports`.** Chỉ container trong cùng mạng Docker mới gọi được. Cổng 8080 không lộ ra Internet. |
| `PASSWORD=${CODE_SERVER_PASSWORD}` | Mật khẩu màn hình đăng nhập của code-server. |
| `DOCKER_USER=coder` | Báo entrypoint của base image chạy code-server dưới user `coder`. |
| `- ./workspace:/home/coder/workspace` | **Bind mount.** Mã nguồn nằm thẳng trên host, dễ `scp`, `git clone`, backup bằng `tar` thường. Đổi lại phải `chown 1000:1000` (setup.sh đã làm). |
| `- claude_config:/home/coder/.claude` | Named volume — token đăng nhập không bị lộ ra filesystem host. |

**Các nhãn (labels) Traefik**

Đây là **toàn bộ giao diện** giữa stack này và Traefik có sẵn. Traefik đọc nhãn qua Docker
socket rồi tự sinh router/service/middleware — không cần sửa gì bên phía Traefik.

| Nhãn | Ý nghĩa | Phải khớp với gì bên Traefik |
|---|---|---|
| `traefik.enable=true` | Cho phép Traefik quản lý container này | Bắt buộc, vì Traefik đặt `exposedByDefault: false` |
| `traefik.docker.network=traefik-net` | Chỉ rõ Traefik phải kết nối tới container qua network nào | `providers.docker.network` của Traefik |
| `traefik.http.routers.claude.rule=Host(...)` | Chỉ nhận request có `Host` khớp `${DOMAIN}` | — |
| `traefik.http.routers.claude.entrypoints=websecure` | Chỉ lắng nghe trên cổng 443 | tên entryPoint `websecure` |
| `traefik.http.routers.claude.tls=true` | Bật TLS cho router | — |
| `traefik.http.routers.claude.tls.certresolver=letsencrypt` | Nhờ Traefik xin chứng chỉ cho `${DOMAIN}` | tên certificatesResolver `letsencrypt` |
| `traefik.http.routers.claude.service=claude` | Trỏ router tới service `claude` khai ngay dưới | — |
| `traefik.http.routers.claude.middlewares=claude-auth@docker` | Chuỗi middleware áp cho router | `claude-auth` khai ngay trong file này |
| `traefik.http.middlewares.claude-auth.basicauth.users=...` | Định nghĩa BasicAuth (lớp 1) | — |
| `traefik.http.services.claude.loadbalancer.server.port=8080` | Cổng bên trong container | phải là `8080` của code-server |

```yaml
- "traefik.http.routers.claude.rule=Host(`${DOMAIN}`)"
```
Dấu **backtick** bao quanh là cú pháp bắt buộc của Traefik, không phải markdown.

```yaml
- "traefik.http.routers.claude.middlewares=claude-auth@docker"
```
Hậu tố sau `@` cho biết middleware được định nghĩa ở đâu:

- `@docker` — định nghĩa bằng nhãn ngay trong `docker-compose.yml` này
- `@file` — định nghĩa trong file dynamic của **stack Traefik** (`dynamic.yml`)

Hiện tại chuỗi này **chỉ có một** middleware. Hai middleware `secure-headers@file` và
`gzip@file` của bản cũ đã bị bỏ, vì chúng từng nằm trong `traefik/dynamic/middlewares.yml`
của repo này — file đó đã bị xoá và Traefik có sẵn không nạp nó.

> ### 🚨 Traefik v3: tham chiếu middleware không tồn tại = mất luôn router
>
> Nếu router trỏ tới một middleware chưa được nạp, Traefik v3 **bỏ qua toàn bộ router**, và
> bạn nhận **404** — chứ không phải "vẫn chạy nhưng thiếu header". Đây là lỗi rất khó đoán
> vì container `claude-code` vẫn `healthy`, log vẫn sạch.
>
> Muốn bật lại `secure-headers` / `gzip`, **bắt buộc** làm đúng thứ tự trong
> [Phụ lục D](#phụ-lục-d--bật-thêm-middleware-bảo-mật-tuỳ-chọn): nạp middleware bên Traefik
> **trước**, xác nhận log sạch, rồi mới sửa nhãn ở đây.

```yaml
- "traefik.http.middlewares.claude-auth.basicauth.users=${BASIC_AUTH_USER}:${BASIC_AUTH_HASH}"
```

> ### ⚠️ Đây là chỗ dễ sai nhất của toàn bộ stack
>
> Docker Compose **có nội suy biến ngay trong chính file `.env`**. Nghĩa là ký tự `$` trong
> `.env` vẫn mang ý nghĩa đặc biệt. Hash bcrypt luôn chứa `$` (dạng `$2y$05$...`).
>
> **Mọi `$` trong `BASIC_AUTH_HASH` phải được viết thành `$$` ngay trong file `.env`.**
>
> ```
> Hash thật:      $2y$05$abcdefgh...
> Ghi trong .env: $$2y$$05$$abcdefgh...
> ```
>
> `scripts/setup.sh` làm việc này tự động (bước 5/9) và **tự kiểm chứng lại** (bước 6/9) bằng
> cách gọi `docker compose config`, lấy nhãn đã được giải mã và so với hash gốc.

### 4.3. `docker/entrypoint.d/10-claude-config.sh`

Entrypoint của base image code-server có sẵn cơ chế: nó tìm mọi file **có quyền thực thi**
trong thư mục `$ENTRYPOINTD` và chạy chúng trước khi khởi động code-server.

Script này bảo đảm `~/.claude.json` nằm trong volume (xem giải thích ở mục 3.2). Nó
idempotent, và **mọi lỗi đều bị nuốt** — nếu hỏng thì chỉ ghi cảnh báo, container vẫn khởi
động bình thường để bạn còn vào sửa được.

Muốn thêm script khởi động của riêng bạn (ví dụ cấu hình git):

```bash
# tạo file docker/entrypoint.d/20-git-config.sh
#!/bin/sh
git config --global user.name  "Ten Cua Ban"  || true
git config --global user.email "ban@example.com" || true
```

Rồi `docker compose up -d --build`. Dockerfile tự `chmod +x` cho mọi `*.sh` trong thư mục đó.

---

## 5. Vận hành hằng ngày

### 5.1. Các lệnh cơ bản

Tất cả chạy trong thư mục `~/claude-vps`:

```bash
docker compose ps                    # xem trạng thái container claude-code
docker compose logs -f               # xem log của stack (Ctrl+C để thoát)
docker compose logs -f claude-code   # chỉ log code-server

docker compose restart               # khởi động lại
docker compose restart claude-code   # chỉ khởi động lại code-server

docker compose stop                  # dừng, giữ nguyên mọi dữ liệu
docker compose start                 # chạy lại

docker compose down                  # xoá container, GIỮ volume  ✅ an toàn
# docker compose down -v             # XOÁ CẢ VOLUME  🚨 mất đăng nhập Claude

docker stats --no-stream             # xem RAM/CPU đang dùng
docker compose exec claude-code bash # vào shell của container
```

**Xem log của Traefik** — Traefik **không thuộc stack này**, nên `docker compose logs traefik`
sẽ báo không tìm thấy service. Dùng `docker logs` thẳng theo tên container:

```bash
docker logs -f traefik               # log Traefik (xem lỗi ACME / định tuyến ở đây)
docker logs --tail=100 traefik

# hoặc vào hẳn thư mục stack Traefik để dùng compose của nó
cd /home/N8N/traefik-stack && docker compose logs -f
```

> 🚨 `docker compose down` trong `~/claude-vps` **không** làm sập Traefik hay các site khác:
> network `traefik-net` là `external` nên Compose không đụng tới. Ngược lại, restart
> Traefik ở `/home/N8N/traefik-stack` sẽ làm gián đoạn **tất cả** site đi qua nó, kể cả cái này.

### 5.2. Cập nhật Claude Code

**Cách nhanh — ngay trong terminal của code-server** (hiệu lực tới khi rebuild image):

```bash
npm install -g @anthropic-ai/claude-code@latest
claude --version
```

Chạy được mà không cần `sudo` nhờ `NPM_CONFIG_PREFIX` trỏ vào thư mục home.

**Cách bền — rebuild image** (khuyến nghị, để bản mới nằm luôn trong image):

```bash
cd ~/claude-vps
docker compose build --no-cache claude-code
docker compose up -d
docker compose exec claude-code claude --version
```

Token đăng nhập nằm ở volume nên **rebuild không làm mất đăng nhập**.

### 5.3. Cập nhật code-server

1. Xem tag mới nhất tại `https://hub.docker.com/r/codercom/code-server/tags`
2. Sửa dòng đầu `Dockerfile`:

   ```dockerfile
   FROM codercom/code-server:4.135.0-bookworm
   ```

3. Chạy:

   ```bash
   docker compose build claude-code
   docker compose up -d
   ```

Cài đặt và extension nằm ở volume `code_config` nên được giữ nguyên.

### 5.4. Cập nhật Traefik — **không phải việc của stack này**

`docker-compose.yml` trong `~/claude-vps` **không có service `traefik`**, nên không có gì để
nâng cấp ở đây. Traefik thuộc stack riêng:

```bash
cd /home/N8N/traefik-stack
# sửa image: traefik:v3.x.y trong docker-compose.yml của stack ĐÓ, rồi:
docker compose pull
docker compose up -d
docker logs --tail 50 traefik
```

> ### 🚨 Nâng cấp Traefik ảnh hưởng MỌI site trên VPS
>
> Không chỉ `code.example.com` mà cả `traefik.example.com` và mọi container khác đang gắn
> nhãn. Làm ngoài giờ, và **đọc changelog trước**.
>
> - Chỉ nâng cấp trong **nhánh v3**. Nhảy v2 → v3 đổi cú pháp rất nhiều (ví dụ
>   `ipwhitelist` → `ipallowlist`).
> - Sau khi nâng cấp, kiểm tra lại stack này còn route được không:
>   `curl -s -o /dev/null -w '%{http_code}\n' https://code.example.com/` → mong đợi `401`.

### 5.5. Sao lưu

```bash
bash scripts/backup.sh
```

Tạo file `backups/claude-vps-YYYYmmdd-HHMMSS.tar.gz` chứa:

- `claude_config.tar.gz` — **token đăng nhập Claude** (quan trọng nhất)
- `code_config.tar.gz` — cài đặt + extension
- `workspace.tar.gz` — mã nguồn
- `config/.env`, `config/docker-compose.yml`, `config/Dockerfile`

> ⚠️ Danh sách file cấu hình trong `scripts/backup.sh` **vẫn còn liệt kê**
> `traefik/acme.json` và `traefik/traefik.yml` từ thời stack tự chạy Traefik. Hai file đó
> không còn tồn tại, nên script chỉ in cảnh báo `... khong ton tai - bo qua` rồi đi tiếp —
> **không phải lỗi**, bản sao lưu vẫn hợp lệ. Vì thế phần "cách phục hồi" script in ra cuối
> cũng có 2 dòng `cp .../traefik/...`, bạn **bỏ qua 2 dòng đó** khi restore.
>
> **Chứng chỉ HTTPS không nằm trong bản sao lưu này** — nó thuộc stack Traefik. Muốn sao lưu
> chứng chỉ thì sao lưu `acme.json` ở `/home/N8N/traefik-stack`.

Mặc định giữ 7 bản gần nhất. Đổi bằng:

```bash
KEEP=14 bash scripts/backup.sh
```

Script tự in ra **lệnh phục hồi tương ứng** ở cuối. Đọc kỹ phần đó khi cần restore.

**Sao lưu tự động hằng ngày lúc 2 giờ sáng:**

```bash
crontab -e
# thêm dòng (sửa lại đường dẫn cho đúng):
0 2 * * * cd /home/user/claude-vps && bash scripts/backup.sh >> /var/log/claude-backup.log 2>&1
```

**Chép bản sao lưu ra ngoài VPS** (rất nên làm — bản sao lưu nằm cùng máy thì vô nghĩa khi
máy hỏng):

```powershell
# chạy trên máy Windows
scp user@203.0.113.45:~/claude-vps/backups/claude-vps-*.tar.gz D:\backup\
```

### 5.6. Đổi mật khẩu

```bash
cd ~/claude-vps
bash scripts/setup.sh --regen-auth
```

Sinh lại cả mật khẩu BasicAuth lẫn mật khẩu code-server, cập nhật `.env`, khởi động lại
stack và in mật khẩu mới ra màn hình.

### 5.7. Dọn dẹp ổ cứng

```bash
docker image prune -a      # xoá image không dùng
docker builder prune       # xoá cache build
df -h                      # kiểm tra dung lượng còn lại
```

⚠️ **Đừng chạy `docker system prune --volumes`** — cờ `--volumes` sẽ xoá volume và bạn mất
đăng nhập Claude.

### 5.8. Chạy `claude` 24/7 (bền phiên) với tmux

Đây là cách để phiên `claude` **không chết khi bạn đóng tab, mất mạng, hay khoá điện thoại**.
Xem [mục 6.9-B](#69-terminal-trong-code-server-không-mở-được--hoặc-đóng-tab-là-mất-phiên-claude)
để hiểu vì sao terminal thường lại không bền.

**Cách dùng — chỉ một lệnh:**

```bash
cc
```

`cc` xử lý cả ba tình huống, bạn không cần nhớ đang ở tình huống nào:

| Tình huống | `cc` làm gì |
|---|---|
| Chưa có phiên tmux nào | Tạo phiên tên `claude` và chạy `claude` bên trong |
| Có phiên nhưng đang là **shell trống** (container vừa khởi động xong) | Chạy `claude` vào đó **một lần**, rồi gắn vào |
| Có phiên và `claude` đang chạy dở | **Gắn thẳng vào**, không đụng gì cả |

Nghĩa là những lần sau — mở lại tab, đổi máy, đổi điện thoại — cứ gõ `cc` là **về đúng phiên
cũ**, thấy nguyên output đang chạy dở.

> `cc` là script cài sẵn trong image (`/usr/local/bin/cc`). Container còn tự tạo sẵn một phiên
> `claude` rỗng mỗi lần khởi động (hook `20-tmux-session.sh`), nên kể cả sau khi restart, gõ
> `cc` là có ngay.

**Vì sao phiên rỗng lại được tạo sẵn mà không chạy luôn `claude`?** Vì lần đầu container khởi
động bạn chưa đăng nhập — nếu chạy ngay, màn hình đăng nhập sẽ hiện trong một phiên nền mà
không ai nhìn thấy. Nên hook chỉ mở sẵn shell, còn `cc` mới là thứ khởi động `claude`.

> **Lưu ý về việc tự khởi động:** `cc` chỉ tự gõ lệnh `claude` khi pane đang là shell trống,
> và chỉ đúng **một lần** cho mỗi phiên. Nếu bạn đang mở `vim`, `htop`… hoặc đã chủ động thoát
> `claude` để ngồi ở shell, `cc` sẽ **không** gõ chen vào. Muốn chạy lại thì tự gõ `claude`.

**Các phím tắt tmux cần biết** (bấm `Ctrl+b` trước, thả ra, rồi bấm phím sau):

| Thao tác | Phím |
|---|---|
| **Detach** — rời phiên nhưng để nó chạy tiếp | `Ctrl+b` rồi `d` |
| Tách cửa sổ dọc / ngang | `Ctrl+b` rồi `%` / `"` |
| Chuyển qua lại giữa các pane | `Ctrl+b` rồi phím mũi tên |
| Cuộn xem lại output (chế độ copy) | `Ctrl+b` rồi `[`, thoát bằng `q` |
| Tạo cửa sổ mới | `Ctrl+b` rồi `c` |

**Lưu ý khi dùng trên điện thoại:** file cấu hình đã **bật mouse mode**, nên bạn **cuộn
scrollback bằng cách vuốt ngón tay** ngay trên terminal (không cần phím PageUp — điện thoại
không có). Chạm để chọn pane cũng được. Lịch sử cuộn giữ tới 50.000 dòng.

**Thoát hẳn phiên:** trong `claude` gõ `/exit` (hoặc `exit` trong shell) để đóng phiên; lần
sau `cc` sẽ tạo phiên mới.

### 5.9. Chạy nền không cần ngồi canh (headless)

Khi cần Claude làm một việc dài mà **không ai ngồi canh**, dùng chế độ *headless*
(`claude -p "..."`): chạy một lượt rồi thoát, ghi log ra file. Repo có sẵn script minh hoạ:

```bash
# Trong terminal code-server (thư mục workspace):
bash scripts/run-headless.sh "Tóm tắt các thay đổi trong repo và đề xuất bước tiếp theo"

# Hoặc đọc prompt từ file:
bash scripts/run-headless.sh --file prompts/task.txt
```

Log ghi vào `workspace/logs/claude-headless-<timestamp>.log` để xem lại sau.

> 🚨 **Rủi ro về quyền tool.** Ở chế độ tương tác, Claude **hỏi** trước khi chạy lệnh shell.
> Ở headless **không có ai để hỏi**. Script mặc định chỉ cấp trước vài tool đọc-only an toàn
> (`Read`, `Grep`, `git log`...), nên việc nào cần tool ngoài danh sách sẽ **dừng lại** —
> an toàn nhưng có thể "không làm được gì". Cờ `--dangerously-skip-permissions` cho phép Claude
> chạy **bất kỳ lệnh nào không hỏi** (kể cả xoá file) — script **KHÔNG** bật mặc định; chỉ
> bật khi bạn hiểu rõ rủi ro (đặt `DANGEROUS=1` khi gọi) và tin tưởng prompt.

---

## 6. Xử lý sự cố

### 6.1. Trình duyệt báo lỗi chứng chỉ / không có HTTPS

**Triệu chứng:** `ERR_CERT_AUTHORITY_INVALID`, "Kết nối không riêng tư", hoặc Traefik trả
chứng chỉ tự ký `TRAEFIK DEFAULT CERT`.

Việc xin chứng chỉ **hoàn toàn nằm ở phía Traefik có sẵn** — stack này chỉ nói "hãy dùng
certresolver `letsencrypt`" qua nhãn. Vì vậy phải chẩn đoán từ phía Traefik.

**Chẩn đoán:**

```bash
# 1. Log của Traefik (KHÔNG dùng "docker compose logs" trong ~/claude-vps -
#    Traefik không thuộc stack này)
docker logs traefik 2>&1 | grep -i -E 'acme|certificate|error'

# 2. DNS có trỏ đúng về VPS này không?
getent hosts code.example.com          # DNS trả về IP nào?
curl -s https://ifconfig.me; echo      # IP thật của VPS  -> hai giá trị phải trùng

# 3. Cổng 80 có mở và có đang do Traefik giữ không?
#    certresolver "letsencrypt" dùng httpChallenge qua entrypoint "web" (:80)
sudo ss -lntp | grep -E ':80|:443'
curl -sI http://code.example.com/ | head -3    # từ ngoài phải tới được cổng 80

# 4. Nhãn certresolver có đúng tên không?
docker compose config | grep certresolver
# mong đợi: ...tls.certresolver: letsencrypt
```

**Nguyên nhân và cách sửa:**

| Log Traefik chứa | Nguyên nhân | Cách sửa |
|---|---|---|
| `unable to generate a certificate ... timeout during connect` | Cổng 80 bị chặn → httpChallenge không tới được | `sudo ufw allow 80/tcp` + mở 80 ở firewall của nhà cung cấp VPS |
| `DNS problem: NXDOMAIN` | Chưa tạo bản ghi A | Tạo bản ghi A, chờ DNS lan truyền |
| `Invalid response from http://...` trả về nội dung lạ | DNS trỏ sai máy, hoặc Cloudflare đang proxy | Sửa bản ghi A; tắt proxy Cloudflare (đám mây xám) |
| `too many certificates already issued` | Chạm rate limit Let's Encrypt (**5 chứng chỉ trùng lặp / tên miền / tuần**) | Chờ hết tuần, hoặc dùng tạm một subdomain khác. Xem ghi chú staging bên dưới |
| `the ACME storage file ... permissions 644` | `acme.json` **của stack Traefik** sai quyền | Sửa trong `/home/N8N/traefik-stack`, không phải ở đây |
| Không có dòng ACME nào nhắc tới tên miền của bạn | Router chưa được tạo → Traefik chưa biết cần xin chứng chỉ cho host nào | Xem [mục 6.7](#67-container-chạy-nhưng-traefik-không-tạo-route-404) |

> ### 🚨 Muốn thử máy chủ staging của Let's Encrypt?
>
> Bản cũ của tài liệu hướng dẫn bỏ comment `caServer` trong `traefik/traefik.yml` —
> **file đó không còn tồn tại trong repo này**. `caServer` thuộc cấu hình tĩnh của Traefik
> có sẵn (`/home/N8N/traefik-stack`).
>
> Đổi nó sẽ khiến **tất cả** site trên VPS chuyển sang chứng chỉ staging (trình duyệt báo
> lỗi đỏ ở mọi tên miền), và bắt buộc phải xoá `acme.json` cũ để Traefik không dùng lại bản
> cache. **Không nên làm** trên một Traefik đang phục vụ nhiều site. Cách an toàn hơn để
> tránh đốt hạn mức: kiểm tra kỹ DNS + cổng 80 **trước** khi `docker compose up -d`, đúng
> như bước 7/9 của `setup.sh` đã làm.

Nếu chứng chỉ chỉ đơn giản là chưa kịp cấp: chờ 30–90 giây rồi tải lại trang, và theo dõi
`docker logs -f traefik`.

### 6.2. `502 Bad Gateway`

**Triệu chứng:** Qua được BasicAuth nhưng trang hiện `502 Bad Gateway`.

**Chẩn đoán:**

```bash
docker compose ps                          # claude-code có "healthy" không?
docker compose logs --tail=80 claude-code

# CẢ HAI container (traefik và claude-code) phải cùng nằm trong traefik-net
docker network inspect traefik-net \
    --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'

docker compose exec claude-code curl -sI http://127.0.0.1:8080/healthz
```

**Nguyên nhân thường gặp:**

| Nguyên nhân | Cách sửa |
|---|---|
| Container còn đang khởi động | Chờ 60 giây (`start_period` của healthcheck) |
| Container bị crash | Đọc log, thường do hết RAM — xem mục 6.5 |
| Sai nhãn `traefik.docker.network` | Phải bằng `traefik-net`, khớp `networks.web.name` trong compose **và** `providers.docker.network` của Traefik |
| `traefik` không có trong `traefik-net` | Kiểm tra lại stack ở `/home/N8N/traefik-stack` |
| Sai `loadbalancer.server.port` | Phải là `8080` |
| Sửa compose xong quên áp dụng | `docker compose up -d` |

### 6.3. BasicAuth luôn báo sai mật khẩu

**Triệu chứng:** Nhập đúng user/pass mà hộp thoại cứ hiện lại, hoặc trả về `401`.

**Nguyên nhân số 1 — quên nhân đôi `$`.**

**Chẩn đoán:**

```bash
# 1. Xem hash trong .env - PHẢI thấy $$ (hai dấu đô la liền nhau)
grep BASIC_AUTH_HASH .env

# 2. Xem nhãn SAU KHI compose đã giải mã - PHẢI thấy $ đơn (một dấu)
docker compose config | grep basicauth
```

Kết quả đúng trông như thế này:

```
# trong .env         : BASIC_AUTH_HASH=$$2y$$05$$abcdefghijk...
# trong compose config: ...basicauth.users: admin:$2y$05$abcdefghijk...
```

| Bạn thấy gì ở `compose config` | Chẩn đoán | Cách sửa |
|---|---|---|
| `$$2y$$05$$...` (còn `$$`) | Escape hai lần | `bash scripts/setup.sh --regen-auth` |
| `admin:2y05...` (mất hết `$`) | **Quên escape** — compose đã "ăn" mất các `$` | `bash scripts/setup.sh --regen-auth` |
| `admin:$2y$05$...` mà vẫn 401 | Hash đúng, mật khẩu bạn nhập sai | Sinh lại: `bash scripts/setup.sh --regen-auth` |

**Cách sửa nhanh nhất (khuyến nghị):**

```bash
bash scripts/setup.sh --regen-auth
```

**Phương án dự phòng — dùng `usersfile` (hoàn toàn không dính escaping):**

Nếu vì lý do nào đó việc escaping cứ hỏng, có thể cho Traefik đọc thẳng file htpasswd. Nhưng
lưu ý: nhãn `basicauth.usersfile` khai một **đường dẫn bên trong container `traefik`**, mà
container đó thuộc stack `/home/N8N/traefik-stack` — nên **mount phải thêm ở stack Traefik**,
không phải ở đây.

```bash
# 1. Tạo file htpasswd trong thư mục của STACK TRAEFIK (KHÔNG cần escape gì cả)
sudo apt-get install -y apache2-utils
cd /home/N8N/traefik-stack
htpasswd -cbB ./usersfile-claude admin 'MatKhauCuaBan'
chmod 600 ./usersfile-claude
```

```yaml
# 2. Trong docker-compose.yml CỦA STACK TRAEFIK, service traefik: thêm mount
    volumes:
      - ./usersfile-claude:/etc/traefik/usersfile-claude:ro
```

```bash
# 3. Áp dụng ở stack Traefik (làm gián đoạn mọi site vài giây)
cd /home/N8N/traefik-stack && docker compose up -d
```

```yaml
# 4. QUAY LẠI ~/claude-vps, trong service claude-code: thay nhãn basicauth.users bằng
      - "traefik.http.middlewares.claude-auth.basicauth.usersfile=/etc/traefik/usersfile-claude"
#    (xoá dòng basicauth.users cũ đi)
```

```bash
# 5. Áp dụng
cd ~/claude-vps && docker compose up -d
```

> 🚨 **Đừng làm ngược thứ tự.** Sửa nhãn ở bước 4 trước khi mount xong ở bước 3 sẽ khiến
> Traefik không đọc được file → BasicAuth hỏng, hoặc router bị bỏ qua (404).
>
> Thành thật mà nói: cách này **thêm sự phụ thuộc chéo giữa hai stack** và làm việc bảo trì
> rối hơn hẳn. `bash scripts/setup.sh --regen-auth` đã tự lo escaping và tự kiểm chứng lại —
> gần như luôn là lựa chọn đúng. Chỉ dùng `usersfile` khi bạn thật sự cần đặt mật khẩu
> BasicAuth do mình tự chọn.

### 6.4. Claude Code báo mất đăng nhập

**Triệu chứng:** Gõ `claude` lại hỏi đăng nhập từ đầu, dù trước đó đã đăng nhập rồi.

**Chẩn đoán:**

```bash
# Volume còn tồn tại không?
docker volume ls | grep claude_config

# File credentials còn không?
docker compose exec claude-code ls -la /home/coder/.claude/

# Biến môi trường có đúng không?
docker compose exec claude-code printenv CLAUDE_CONFIG_DIR
# mong đợi: /home/coder/.claude

# Quyền thư mục có đúng user coder (uid 1000) không?
docker compose exec claude-code stat -c '%U:%G %a' /home/coder/.claude
# mong đợi: coder:coder 700

# Công cụ tự chẩn đoán của Claude
docker compose exec -it claude-code claude doctor
```

| Nguyên nhân | Dấu hiệu | Cách sửa |
|---|---|---|
| Ai đó chạy `docker compose down -v` | `docker volume ls` không còn `claude_config` | Phục hồi từ bản sao lưu, hoặc đăng nhập lại bằng `claude` |
| Thư mục thuộc `root` | `stat` trả về `root:root` | `docker compose exec -u root claude-code chown -R coder:coder /home/coder/.claude` rồi restart |
| `CLAUDE_CONFIG_DIR` bị rỗng | `printenv` không in ra gì | Kiểm tra dòng `ENV CLAUDE_CONFIG_DIR` trong Dockerfile, rebuild |
| `~/.claude.json` không persist | `ls -la /home/coder/.claude.json` không phải symlink | Kiểm tra hook: `docker compose logs claude-code \| grep 10-claude-config` |

Đăng nhập lại: mở terminal trong code-server, gõ `claude`, dùng lệnh `/login`.

### 6.5. Chậm, treo, hoặc container tự khởi động lại (OOM)

**Chẩn đoán:**

```bash
docker stats --no-stream
free -h
docker inspect claude-code --format '{{.State.OOMKilled}} {{.RestartCount}}'
#              ^ nếu in ra "true" nghĩa là bị kernel giết vì hết RAM
dmesg | tail -30 | grep -i 'killed process'
```

**Cách sửa:**

```bash
# 1. Nới giới hạn RAM trong .env (nếu VPS còn dư)
nano .env
#    CLAUDE_MEM_LIMIT=6g
#    CLAUDE_CPU_LIMIT=4
docker compose up -d

# 2. Hoặc thêm swap (xem mục 1.1)

# 3. Hoặc nâng cấp VPS lên 4 GB+
```

Mẹo giảm tải: đóng bớt tab/extension trong code-server; tránh mở repo cực lớn cùng lúc với
phiên Claude dài.

### 6.6. `bash\r: No such file or directory`

**Triệu chứng:**

```
/usr/bin/env: 'bash\r': No such file or directory
```

**Nguyên nhân:** File soạn trên Windows còn ký tự `CRLF`.

**Cách sửa:**

```bash
cd ~/claude-vps
find . -type f \( -name '*.sh' -o -name 'Dockerfile' -o -name '*.yml' -o -name '*.template' \) \
     -exec sed -i 's/\r$//' {} +
docker compose build --no-cache claude-code
docker compose up -d
```

**Phòng ngừa:** repo đã có `.gitattributes` ép `eol=lf`. Trên máy Windows nên đặt:

```powershell
git config --global core.autocrlf input
```

### 6.7. Container chạy nhưng Traefik không tạo route (404)

**Triệu chứng:** `docker compose ps` thấy `claude-code` **healthy**, log container sạch,
nhưng vào `https://code.example.com` thì nhận **404 page not found** — và hộp thoại BasicAuth
thậm chí **không hiện ra**.

Đây là triệu chứng đặc trưng của "Traefik không nhìn thấy container này", chứ không phải
"code-server hỏng". Kiểm tra theo đúng thứ tự sau:

```bash
cd ~/claude-vps

# 1. Nhãn đã được compose giải mã đúng chưa?
docker compose config | grep -E 'traefik\.'

# 2. Nhãn có thật sự nằm trên container đang chạy không?
docker inspect claude-code --format '{{json .Config.Labels}}' | tr ',' '\n' | grep traefik

# 3. Container có nằm trong traefik-net không? (phải liệt kê được cả 2 tên)
docker network inspect traefik-net \
    --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'

# 4. Traefik nói gì?
docker logs --tail 60 traefik
```

| Dấu hiệu | Nguyên nhân | Cách sửa |
|---|---|---|
| Không có nhãn `traefik.enable=true` | Traefik đặt `exposedByDefault: false` nên bỏ qua container | Thêm lại nhãn, `docker compose up -d` |
| `claude-code` không có trong `traefik-net` | Khối `networks` trong compose sai tên, hoặc quên `- web` ở service | Sửa `networks.web.name: traefik-net` + `external: true` |
| Log: `middleware "secure-headers@file" does not exist` (hoặc tên middleware khác) | **Traefik v3 bỏ qua TOÀN BỘ router** khi middleware không tồn tại → 404 | Bỏ middleware đó khỏi nhãn, hoặc nạp nó theo [Phụ lục D](#phụ-lục-d--bật-thêm-middleware-bảo-mật-tuỳ-chọn) |
| Log: `entryPoint "websecure" doesn't exist` | Tên entrypoint không khớp Traefik có sẵn | Đổi nhãn `entrypoints` cho khớp (mục 0.1) |
| Log: `certificate resolver ... does not exist` | Tên certresolver sai (bản cũ dùng `le`) | Phải là `letsencrypt` |
| Log: `Could not find network ...` / router trỏ IP lạ | Nhãn `traefik.docker.network` khác `traefik-net` | Sửa cho khớp |
| `docker compose up -d` báo `network traefik-net declared as external, but could not be found` | Stack Traefik chưa chạy | `cd /home/N8N/traefik-stack && docker compose up -d` |

Không thấy gì bất thường? Mở **dashboard của Traefik** ở `https://traefik.example.com`
(Traefik có sẵn đã bật sẵn, dùng BasicAuth riêng của nó) → tab **HTTP → Routers**, tìm router
`claude@docker`. Router hiện màu đỏ kèm mô tả lỗi là cách nhanh nhất để biết nhãn nào sai.

> Traefik có sẵn giữ cổng 80/443, nên nếu **chính Traefik** không khởi động được
> (`bind: address already in use`, sai cú pháp YAML...) thì phải xử lý trong
> `/home/N8N/traefik-stack`, không phải trong repo này:
>
> ```bash
> sudo ss -lntp | grep -E ':80|:443'   # dịch vụ nào đang giữ cổng?
> docker logs --tail 50 traefik
> ```

### 6.8. Không ghi được file trong `workspace`

**Triệu chứng:** VS Code báo `EACCES: permission denied` khi lưu file.

**Nguyên nhân:** Thư mục `./workspace` trên host thuộc `root`, trong khi container chạy bằng
user `coder` (uid 1000).

**Cách sửa:**

```bash
sudo chown -R 1000:1000 ~/claude-vps/workspace
docker compose restart claude-code
```

Áp dụng cả sau khi bạn `git clone` hay `scp` bằng `sudo` vào thư mục đó.

### 6.9. Terminal trong code-server không mở được — hoặc "đóng tab là mất phiên `claude`"

**Hai triệu chứng khác nhau, đọc đúng phần của bạn:**

#### A. Terminal không mở ra được

```bash
docker compose exec claude-code bash        # từ VPS có vào được shell không?
docker compose logs claude-code | tail -50
```

Thường do trình duyệt chặn WebSocket (extension chặn quảng cáo) hoặc reverse proxy khác
chen giữa. Thử tab ẩn danh, tắt extension. Nếu bạn có proxy riêng (nginx/Cloudflare) đứng
trước Traefik, phải bật chuyển tiếp WebSocket (`Upgrade` / `Connection` headers) — xem
thêm [mục 6.11](#611-cloudflare-proxy-đám-mây-cam-làm-rớt-phiên-và-hỏng-chứng-chỉ) về Cloudflare.

#### B. Đóng tab / khoá điện thoại là phiên `claude` chết theo, mất việc đang chạy dở

**Đây là hành vi BÌNH THƯỜNG của terminal code-server, không phải lỗi.** Hiểu tại sao:

- Terminal tích hợp của code-server là một tiến trình shell **con của phiên WebSocket** giữa
  trình duyệt và server. Khi bạn đóng tab, mất mạng, hoặc — đặc biệt trên **điện thoại** —
  trình duyệt tự "ngủ đông" (kill) tab chạy nền để tiết kiệm pin, WebSocket đứt. code-server
  coi như bạn đã rời đi và **gửi tín hiệu kết thúc cho shell đó** cùng mọi tiến trình con,
  trong đó có `claude`. Kết quả: phiên đang chạy dở biến mất.
- Bản thân code-server **không** giữ lại buffer terminal qua lần mất kết nối như vậy.

**Cách giải quyết: chạy `claude` bên trong `tmux`.** `tmux` là một "terminal multiplexer" —
nó tạo ra một phiên **sống độc lập với trình duyệt**, nằm hẳn bên trong container. Tab trình
duyệt chỉ là một cửa sổ **nhìn vào** phiên tmux đó; đóng cửa sổ không giết phiên. Mở lại tab,
gõ một lệnh để "gắn" (attach) lại, bạn thấy đúng phiên cũ với toàn bộ output còn nguyên.

Image này **đã cài sẵn tmux** và tạo sẵn một phiên tên `claude` mỗi khi container khởi động.
Bạn chỉ cần dùng lệnh tắt `cc` — xem [mục 5.8](#58-chạy-claude-247-bền-phiên-với-tmux).

---

### 6.10. Container bị OOM-kill / tự restart — mất sạch cả phiên tmux

**Triệu chứng:** đang chạy ngon thì cả code-server lẫn phiên `claude` **biến mất cùng lúc**,
container tự khởi động lại. Khác với "đóng tab mất phiên" ở mục 6.9: lần này **tmux cũng không
cứu được**, vì khi kernel OOM-kill container thì chính tiến trình `tmux server` cũng chết theo.

**Nguyên nhân thường gặp nhất:** container vượt `CLAUDE_MEM_LIMIT` (mặc định `3g`) và bị
kernel giết vì hết RAM. Claude Code + build + test + LibreOffice/LaTeX ngốn RAM rất nhanh.

**Chẩn đoán — chạy các lệnh này TRÊN VPS:**

```bash
# OOMKilled=true nghĩa là bị giết vì hết RAM. RestartCount cao = restart nhiều lần.
docker inspect claude-code --format '{{.State.OOMKilled}} {{.RestartCount}} {{.State.StartedAt}}'

# RAM đang dùng so với giới hạn (cột MEM USAGE / LIMIT và MEM %).
docker stats --no-stream claude-code

# Bằng chứng OOM ở tầng kernel (cần quyền root). Tìm dòng nhắc tên container/cgroup.
sudo dmesg | grep -i -E 'oom|killed process' | tail -20
```

**Cách khắc phục:**

- Tăng RAM cho container: sửa `CLAUDE_MEM_LIMIT` trong `.env` (VPS 4 GB để `3g`,
  VPS 8 GB để `6g`), rồi `docker compose up -d` để áp dụng.
- Nếu VPS chỉ 4 GB mà hay OOM: giảm tải song song (đừng chạy build nặng + LaTeX + Claude
  cùng lúc), hoặc nâng cấp gói VPS.
- Sau mỗi lần restart, phiên tmux được tạo lại **rỗng** (nhờ hook khởi động), nhưng công việc
  đang dở thì đã mất — hãy chạy lại. Với việc dài không muốn mất, cân nhắc
  [chế độ headless](#59-chạy-nền-không-cần-ngồi-canh-headless) ghi log ra file.

> Đã đặt `stop_grace_period: 60s` trong `docker-compose.yml` để khi bạn **chủ động**
> `restart`/`stop`, tiến trình trong tmux có 60 giây kết thúc gọn trước khi bị buộc dừng.
> Lưu ý: điều này **không** áp dụng cho OOM-kill — OOM là kernel giết ngay lập tức, không có
> ân hạn.

### 6.11. Cloudflare proxy (đám mây cam) làm rớt phiên và hỏng chứng chỉ

**Nếu bản ghi DNS của bạn đang bật proxy Cloudflare (đám mây MÀU CAM),** bạn đang đi ngược
khuyến cáo ở [mục 1.2](#12-tên-miền-và-bản-ghi-dns) (yêu cầu để **DNS only / màu xám**).
Việc này gây **hai** vấn đề, trong đó vấn đề thứ hai nguy hiểm hơn nhiều:

**Vấn đề 1 — WebSocket chập chờn.** Proxy Cloudflare chen giữa trình duyệt và Traefik.
code-server dựa **hoàn toàn vào WebSocket**; qua proxy CF, kết nối dễ bị **ngắt khi nhàn rỗi
(idle)** hơn hẳn kết nối trực tiếp. Mỗi lần ngắt là một lần terminal code-server "rơi" — nếu
bạn **không** dùng tmux thì mất phiên `claude`.

**Vấn đề 2 — BOM HẸN GIỜ với chứng chỉ.** Proxy CF **chặn HTTP-01 challenge** của Let's
Encrypt. Hôm nay site vẫn chạy bình thường vì chứng chỉ cũ còn hạn, nên rất dễ tưởng là không
sao. Nhưng **đến kỳ gia hạn, Traefik sẽ xin chứng chỉ thất bại**, và khi chứng chỉ cũ hết hạn
thì **site chết hẳn** với lỗi cảnh báo bảo mật trên trình duyệt. Lúc đó mới sửa thì đã mất
dịch vụ. Đây là lý do đủ mạnh để xử lý ngay, độc lập với chuyện rớt phiên.

#### Cách xử lý: tắt proxy, về DNS only

1. Vào Cloudflare → **DNS** → bản ghi `A` của tên miền (ví dụ `code`) → bấm vào biểu tượng
   đám mây cho nó chuyển sang **MÀU XÁM (DNS only)**.
2. **Mở port 80** để HTTP-01 challenge đi tới được — thiếu bước này thì tắt proxy vẫn không
   xin được chứng chỉ:

   ```bash
   sudo ufw allow 80/tcp
   ```

   Và mở cả port 80 ở **firewall của nhà cung cấp VPS** (bảng điều khiển trên web của họ) —
   đây là chỗ hay bị bỏ sót, xem thêm
   [mục 6.1](#61-trình-duyệt-báo-lỗi-chứng-chỉ--không-có-https).
3. Chờ DNS lan truyền (5–30 phút) rồi kiểm chứng:

   ```bash
   # Phải ra IP THẬT của VPS, KHÔNG phải dải 104.x / 172.67.x của Cloudflare
   dig +short code.example.com

   # Phải thấy issuer là Let's Encrypt, KHÔNG phải "Cloudflare Inc ECC CA"
   echo | openssl s_client -connect code.example.com:443 -servername code.example.com 2>/dev/null \
     | openssl x509 -noout -issuer -dates
   ```

**Đánh đổi cần biết:** tắt proxy làm **lộ IP thật của VPS** và **mất lớp chắn DDoS** của
Cloudflare. Bù lại, stack này vẫn còn hai lớp bảo vệ: BasicAuth ở Traefik và mật khẩu đăng
nhập của chính code-server. Nếu lo ngại, hãy siết thêm firewall và cân nhắc fail2ban.

> **Nếu bắt buộc phải giữ proxy cam** (ví dụ chính sách công ty): phải bật **WebSockets**
> (Dashboard → **Network** → **WebSockets = On**), **và** chuyển Traefik sang **DNS-01
> challenge** (cần API token Cloudflare) vì HTTP-01 sẽ không bao giờ chạy được qua proxy.
> Lưu ý cấu hình challenge nằm trong `traefik.yml` của **stack Traefik ngoài repo này**
> (`/home/N8N/traefik-stack`), không phải trong `docker-compose.yml` ở đây. Kết nối qua CF
> vẫn có giới hạn thời gian nhàn rỗi — con số tuỳ gói dịch vụ và có thể thay đổi, tra tài
> liệu Cloudflare hiện hành nếu cần số chính xác, đừng tin con số truyền miệng.

> Dù chọn cách nào, **tmux là lớp phòng thủ nên có**. Nó không sửa được WebSocket chập chờn,
> nhưng khiến việc WebSocket rớt **không còn đồng nghĩa với mất việc**.

---

## 7. Ghi chú bảo mật

### 7.1. Việc bắt buộc phải làm

1. **Không bao giờ commit `.env`.** `.gitignore` đã chặn, nhưng hãy kiểm tra lại:

   ```bash
   git status --short | grep -E '\.env$' && echo "NGUY HIỂM!" || echo "An toàn"
   ```

2. **Sao lưu `acme.json` của stack Traefik** — chứa private key của chứng chỉ. Mất thì phải
   xin lại (và có thể chạm rate limit). File này nằm ở `/home/N8N/traefik-stack`, **không**
   nằm trong repo này và **không** có trong `scripts/backup.sh`.

3. **Đặt quyền 600 cho các file bí mật:**

   ```bash
   chmod 600 .env
   ```

4. **Đổi mật khẩu định kỳ:** `bash scripts/setup.sh --regen-auth`

5. **Cập nhật hệ thống VPS:**

   ```bash
   sudo apt-get update && sudo apt-get upgrade -y
   ```

### 7.2. Giới hạn truy cập theo địa chỉ IP (rất nên làm nếu IP của bạn cố định)

Traefik **v3** dùng tên middleware là `ipallowlist` (v2 dùng `ipwhitelist` — đã bỏ).

Khai bằng **nhãn ngay trong `docker-compose.yml` của stack này** (`@docker`) — cách này gọn
nhất vì không phải đụng tới stack Traefik. Thêm 2 dòng vào khối `labels` của service
`claude-code`:

```yaml
      - "traefik.http.middlewares.ip-allowlist.ipallowlist.sourcerange=203.0.113.0/24,198.51.100.7/32"
      #                                          ^ dải IP văn phòng ^ IP nhà riêng
      - "traefik.http.routers.claude.middlewares=ip-allowlist@docker,claude-auth@docker"
```

Dòng thứ hai **thay thế** dòng `...routers.claude.middlewares=claude-auth@docker` cũ. Thứ tự
chạy từ trái sang phải, nên đặt `ip-allowlist` **đầu tiên** để chặn sớm nhất.

```bash
docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' https://code.example.com/   # từ IP đã cho phép: 401
```

⚠️ Chỉ dùng khi IP của bạn thực sự cố định. IP động của nhà mạng đổi là bạn tự khoá mình
ra ngoài (khi đó vào VPS qua SSH và sửa lại nhãn).

> 🚨 Nhớ hậu tố `@docker`, **không phải `@file`**. Middleware khai bằng nhãn luôn thuộc
> provider `docker`; ghi nhầm `ip-allowlist@file` là Traefik không tìm thấy → **404 toàn bộ
> router** (xem mục 6.7).

### 7.3. fail2ban chống dò mật khẩu

```bash
sudo apt-get install -y fail2ban
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

Mặc định fail2ban đã bảo vệ SSH. Muốn bảo vệ cả BasicAuth của Traefik thì cần viết thêm
filter đọc access log của Traefik — nằm ngoài phạm vi tài liệu này.

### 7.4. Những điều cần biết về mô hình bảo mật

| Điểm | Giải thích |
|---|---|
| **Traefik có quyền đọc Docker socket** | Là Traefik có sẵn của VPS, không phải stack này. Mount `:ro` nên chỉ đọc, nhưng quyền đọc socket vẫn tương đương quyền root trên host. Đây là cách triển khai Traefik tiêu chuẩn; nếu môi trường yêu cầu khắt khe, tìm hiểu thêm về Docker socket proxy. |
| **Traefik dùng chung với các dịch vụ khác trên VPS** | Sửa cấu hình Traefik (`dynamic.yml`, `traefik.yml`, nâng cấp phiên bản) ảnh hưởng **mọi site**, không chỉ site này. Luôn sao lưu trước khi sửa. |
| **User `coder` có `sudo` NOPASSWD trong container** | Do base image code-server thiết lập sẵn — tiện cho việc `apt-get install`. Nghĩa là ai vào được code-server thì có root **trong container** (không phải trên host). Đây chính là lý do phải có hai lớp mật khẩu. |
| **Claude Code có thể chạy lệnh shell** | Người truy cập được code-server điều khiển được cả Claude Code. Giữ mật khẩu thật kín. |
| **HSTS được trình duyệt ghi nhớ 1 năm** | Chỉ áp dụng nếu bạn bật `secure-headers` theo [Phụ lục D](#phụ-lục-d--bật-thêm-middleware-bảo-mật-tuỳ-chọn). Sau khi bật, trình duyệt sẽ **từ chối** truy cập tên miền này qua HTTP. **Mặc định stack này KHÔNG phát header HSTS.** |

---

## 8. Bảng biến môi trường `.env`

| Biến | Bắt buộc | Ví dụ | Mô tả | Lưu ý escaping |
|---|---|---|---|---|
| `DOMAIN` | ✅ | `code.example.com` | **Hostname đầy đủ** đã trỏ DNS A về IP VPS. Dùng trong nhãn `Host()` của Traefik. | — |
| `CODE_SERVER_PASSWORD` | ✅ | `jY3nW8qE5rT2uI7o` | Mật khẩu màn hình đăng nhập của code-server (lớp 2). `setup.sh` tự sinh nếu còn giá trị mẫu. | ⚠️ `$` phải viết thành `$$` |
| `BASIC_AUTH_USER` | ✅ | `admin` | Tên đăng nhập BasicAuth (lớp 1). | — |
| `BASIC_AUTH_HASH` | ✅ | `$$2y$$05$$abc...` | Hash bcrypt của mật khẩu BasicAuth. Do `setup.sh` sinh. | 🚨 **Mọi `$` BẮT BUỘC viết thành `$$`** |
| `TZ` | ❌ | `Asia/Ho_Chi_Minh` | Múi giờ của container. | — |
| `CLAUDE_MEM_LIMIT` | ❌ | `3g` | Giới hạn RAM cho container claude-code. VPS 4 GB → `3g`; VPS 8 GB → `6g`. | — |
| `CLAUDE_CPU_LIMIT` | ❌ | `2` | Giới hạn số CPU (chấp nhận số thập phân, ví dụ `1.5`). | — |
| `ANTHROPIC_API_KEY` | ❌ | `sk-ant-...` | **Mặc định để trống.** Xem Phụ lục A. | ⚠️ `$` → `$$` |
| `CLAUDE_CODE_OAUTH_TOKEN` | ❌ | `sk-ant-oat...` | **Mặc định để trống.** Xem Phụ lục B. | ⚠️ `$` → `$$` |

**Quy tắc escaping — ghi nhớ một câu:** trong file `.env`, muốn có **một** dấu `$` thì phải
gõ **hai** dấu `$$`. Đó là lý do mọi mật khẩu do `setup.sh` sinh ra chỉ gồm **chữ và số**.

> **Biến `ACME_EMAIL` đã bị xoá.** Bản cũ dùng nó để sinh `traefik/traefik.yml`. Giờ chứng chỉ
> do Traefik có sẵn cấp phát, email liên hệ nằm trong cấu hình của stack đó. Nếu `.env` của
> bạn còn sót dòng `ACME_EMAIL=...` thì nó chỉ là rác — không ai đọc, xoá đi cho gọn.

---

## Phụ lục A — Dùng `ANTHROPIC_API_KEY` thay cho tài khoản Pro/Max

### Khi nào cần?

- Bạn không có tài khoản Pro/Max mà dùng tín dụng API trả theo lượng.
- Bạn cần chạy tự động (CI, cron) không có ai ngồi đăng nhập.

### 🚨 Cảnh báo quan trọng về thứ tự ưu tiên

Claude Code xét nguồn xác thực theo thứ tự ưu tiên, trong đó **`ANTHROPIC_API_KEY` đứng
TRƯỚC đăng nhập OAuth bằng subscription**.

Nghĩa là: nếu bạn đã đăng nhập tài khoản Pro/Max **rồi lại set `ANTHROPIC_API_KEY`**, hệ
thống sẽ **bỏ qua gói thuê bao** và tính tiền theo API. Rất dễ mất tiền oan.

### Cách bật

```bash
nano .env
```

```dotenv
ANTHROPIC_API_KEY=sk-ant-api03-xxxxxxxxxxxxxxxxxxxxx
```

```bash
nano docker-compose.yml
```

Bỏ comment dòng tương ứng trong service `claude-code`:

```yaml
    environment:
      - PASSWORD=${CODE_SERVER_PASSWORD}
      - TZ=${TZ}
      - DOCKER_USER=coder
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}     # <-- bỏ dấu # ở đầu
```

```bash
docker compose up -d
docker compose exec claude-code printenv ANTHROPIC_API_KEY
```

### Cách tắt (quay lại dùng subscription)

Comment lại dòng trong `docker-compose.yml`, xoá giá trị trong `.env`, rồi
`docker compose up -d`. Vào terminal gõ `claude` → `/login` để đăng nhập lại bằng tài khoản.

---

## Phụ lục B — Đăng nhập không cần trình duyệt (`claude setup-token`)

Dành cho trường hợp chạy tự động, hoặc bạn muốn tạo token một lần rồi cấu hình sẵn.

### Bước 1 — Sinh token (trên máy cá nhân đã cài Claude Code)

```bash
claude setup-token
```

Lệnh này dẫn qua luồng OAuth trên trình duyệt và sinh ra một token **có hạn 1 năm**, dạng
`sk-ant-oat01-...`.

### Bước 2 — Đưa token vào stack

```bash
nano .env
```

```dotenv
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxxxxxxxxxxxx
```

Bỏ comment dòng tương ứng trong `docker-compose.yml`:

```yaml
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
```

```bash
docker compose up -d
```

### Lưu ý

- Token này **dùng gói thuê bao Pro/Max** của bạn (khác với API key ở Phụ lục A).
- Hết hạn sau 1 năm → phải chạy lại `claude setup-token`.
- Token là bí mật ngang mật khẩu tài khoản. Đừng commit, đừng chia sẻ.
- Cách này **không thay thế** được việc đăng nhập tương tác nếu bạn muốn dùng đầy đủ tính
  năng; luồng ở mục 3 vẫn là cách khuyến nghị cho sử dụng hằng ngày.

---

## Phụ lục C — Đổi `workspace` sang named volume

Mặc định stack dùng **bind mount** `./workspace` — mã nguồn nằm thẳng trên VPS, dễ `scp`,
dễ `git clone`, dễ backup bằng `tar` thường.

Nếu bạn muốn đổi sang **named volume** (Docker tự quản lý, không lộ ra filesystem host,
tránh hoàn toàn chuyện lệch uid/gid), làm như sau.

### So sánh

| | Bind mount `./workspace` (mặc định) | Named volume |
|---|---|---|
| Vị trí trên host | `~/claude-vps/workspace` | `/var/lib/docker/volumes/claude_workspace/_data` |
| Truy cập trực tiếp từ host | ✅ Dễ (`cd`, `ls`, `scp`, `git`) | ❌ Phải qua `sudo` hoặc container tạm |
| Quyền sở hữu | ⚠️ Phải `chown 1000:1000` bằng tay | ✅ Tự kế thừa từ image |
| Sao lưu | ✅ `tar` thường | ⚠️ Cần container tạm |
| Bị xoá bởi `down -v` | ❌ Không | 🚨 **Có** |

### Bước 1 — Sao lưu trước

```bash
cd ~/claude-vps
bash scripts/backup.sh
```

### Bước 2 — Sửa `docker-compose.yml`

Thêm volume vào khối `volumes:` ở cấp cao nhất:

```yaml
volumes:
  claude_config:
    name: claude_config
  code_config:
    name: code_config
  claude_workspace:                 # <-- thêm mới
    name: claude_workspace
```

Trong service `claude-code`, thay dòng bind mount:

```yaml
    volumes:
      - claude_config:/home/coder/.claude
      - code_config:/home/coder/.config
      # - ./workspace:/home/coder/workspace       # <-- comment dòng cũ
      - claude_workspace:/home/coder/workspace    # <-- dùng dòng này
```

### Bước 3 — Chuyển dữ liệu cũ sang volume mới

```bash
docker compose down
docker volume create claude_workspace

# Copy toàn bộ nội dung ./workspace vào volume (giữ nguyên quyền)
docker run --rm \
    -v "$PWD/workspace:/src:ro" \
    -v claude_workspace:/dst \
    alpine:3.20 \
    sh -c 'cp -a /src/. /dst/ && chown -R 1000:1000 /dst'

# Kiểm tra
docker run --rm -v claude_workspace:/data alpine:3.20 ls -la /data

docker compose up -d
```

### Bước 4 — Sửa `scripts/backup.sh`

Đổi dòng khai báo volume:

```bash
VOLUMES="claude_config code_config claude_workspace"
```

Và **xoá / bỏ qua** khối "Sao lưu thư mục ./workspace" (không còn cần `tar` thường nữa).

### Bước 5 — Cách truy cập file sau khi đổi

```bash
# Xem nội dung
docker compose exec claude-code ls -la /home/coder/workspace

# Chép file từ host vào
docker compose cp ./file-cua-toi.py claude-code:/home/coder/workspace/

# Chép file từ container ra host
docker compose cp claude-code:/home/coder/workspace/ketqua.txt ./
```

### 🚨 Điều phải nhớ sau khi đổi

Từ giờ `docker compose down -v` sẽ **xoá cả mã nguồn của bạn**, chứ không chỉ mất đăng nhập.
Hãy chạy `bash scripts/backup.sh` thường xuyên hơn.

---

## Phụ lục D — Bật thêm middleware bảo mật (tuỳ chọn)

### Bối cảnh

Bản cũ của stack tự chạy Traefik riêng và có hai middleware trong
`traefik/dynamic/middlewares.yml`:

- `secure-headers` — HSTS, `X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`...
- `gzip` — nén phản hồi, code-server tải nhanh hơn rõ rệt

Thư mục `traefik/` đã bị xoá, nên **mặc định stack này không có hai middleware đó**. Muốn dùng
lại, phải đưa chúng vào **file dynamic của Traefik có sẵn**.

> ### 🚨 Vì sao không thể chỉ "thả thêm một file .yml"
>
> Traefik có sẵn khai `providers.file` bằng khoá **`filename`**:
>
> ```yaml
> providers:
>   file:
>     filename: /etc/traefik/config/dynamic.yml
>     watch: true
> ```
>
> `filename` trỏ tới **đúng một file**, không phải directory (đó là khoá `directory`). Thả
> `middlewares.yml` vào thư mục `config/` sẽ **không được nạp**, và bạn sẽ ngồi debug 404 rất
> lâu mà không hiểu vì sao. Bắt buộc phải **nối nội dung vào chính `dynamic.yml`**.

### 🚨 Thứ tự thao tác — làm ngược là 404

Traefik v3: nếu router tham chiếu tới một middleware **không tồn tại** thì nó **bỏ qua toàn
bộ router**, trả về **404** — chứ không phải "vẫn chạy nhưng thiếu header". Vì vậy:

**Nạp middleware bên Traefik TRƯỚC → xác nhận log sạch → RỒI MỚI sửa nhãn ở claude-vps.**

Tuyệt đối không đổi nhãn trước.

### Bước 1 — Sao lưu rồi nối thêm vào `dynamic.yml`

File `dynamic.yml` hiện tại chỉ có khoá `tls:` (cấu hình cipher suites), **chưa có khoá
`http:`** — nên nối thêm là an toàn, không trùng key.

```bash
cd /home/N8N/traefik-stack
cp config/dynamic.yml config/dynamic.yml.bak

cat >> config/dynamic.yml <<'EOF'

http:
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: false
        forceSTSHeader: true
        contentTypeNosniff: true
        browserXssFilter: true
        # code-server nhúng webview trong iframe cùng gốc => KHÔNG dùng frameDeny
        frameDeny: false
        customFrameOptionsValue: "SAMEORIGIN"
        referrerPolicy: "strict-origin-when-cross-origin"
        customRequestHeaders:
          X-Forwarded-Proto: "https"
    gzip:
      compress: {}
EOF
```

> Nếu `dynamic.yml` **đã có sẵn** khoá `http:` thì **đừng dùng `cat >>`** — YAML không cho
> phép hai khoá trùng tên ở cùng cấp. Khi đó phải mở `nano config/dynamic.yml` và chèn hai
> middleware vào bên trong khoá `http.middlewares` đã có.

### Bước 2 — Traefik tự nạp lại, kiểm tra log phải SẠCH

`providers.file` đặt `watch: true` nên Traefik nạp lại ngay, **không cần restart**:

```bash
docker logs --tail 30 traefik
```

Log phải không có dòng nào kiểu `error while parsing`, `cannot unmarshal`, `yaml: line ...`.

**Nếu thấy lỗi parse → rollback NGAY:**

```bash
cp config/dynamic.yml.bak config/dynamic.yml
docker logs --tail 30 traefik      # xác nhận đã sạch trở lại
```

> ### 🚨 Vì sao phải rollback ngay
>
> `dynamic.yml` đang giữ **cấu hình TLS cipher suites đang chạy** cho toàn bộ VPS. Parse
> hỏng file này là mất luôn phần đó — ảnh hưởng mọi site, không riêng gì code-server.

Xác nhận middleware đã nạp thành công (một trong hai cách):

- Mở dashboard `https://traefik.example.com` → **HTTP → Middlewares** → phải thấy
  `secure-headers@file` và `gzip@file`.
- Hoặc: `docker logs traefik 2>&1 | grep -i middleware` — không có dòng `does not exist`.

### Bước 3 — Chỉ khi log đã sạch mới sửa nhãn ở `claude-vps`

```bash
cd ~/claude-vps
nano docker-compose.yml
```

Sửa dòng nhãn middleware trong service `claude-code` thành:

```yaml
      - "traefik.http.routers.claude.middlewares=claude-auth@docker,secure-headers@file,gzip@file"
```

Thứ tự chạy từ trái sang phải: BasicAuth chặn trước, rồi mới tới header và nén.

```bash
docker compose up -d

# Kiểm chứng: không có credential -> 401 (router vẫn sống, KHÔNG phải 404)
curl -s -o /dev/null -w '%{http_code}\n' https://code.example.com/

# Xem header đã được thêm chưa
curl -sI -u 'admin:MatKhauBasicAuth' https://code.example.com/ \
    | grep -i -E 'strict-transport|x-frame|x-content-type'
```

| Kết quả `curl` | Nghĩa là |
|---|---|
| `401` | ✅ Đúng — router sống, BasicAuth đang chặn |
| `404` | 🚨 Middleware chưa nạp được → quay lại bước 2, hoặc bỏ `secure-headers@file,gzip@file` khỏi nhãn rồi `docker compose up -d` |

### Ghi chú về HSTS — đọc kỹ trước khi bật

`stsSeconds: 31536000` (1 năm) + `stsIncludeSubdomains: true` khiến trình duyệt **ghi nhớ** và
từ chối truy cập qua HTTP.

Phạm vi ảnh hưởng chính xác:

| Host | Có bị HSTS này áp không? |
|---|---|
| `code.edutechnd.org` (chính host phát header) | ✅ Có |
| `*.code.edutechnd.org` (subdomain **của nó**) | ✅ Có, do `stsIncludeSubdomains` |
| `traefik.edutechnd.org` (host anh em) | ❌ **Không** |
| `edutechnd.org` (tên miền gốc) | ❌ **Không** |

Nói cách khác: `stsIncludeSubdomains` chỉ áp cho **chính hostname phát ra header và các
subdomain CỦA HOSTNAME ĐÓ** — không phải "mọi subdomain của tên miền gốc".

`stsPreload: false` nên tên miền **không** lọt vào preload list được nhúng sẵn trong trình
duyệt. Đây là lựa chọn cố ý: preload rất khó gỡ.

⚠️ Vẫn nên chỉ bật HSTS khi HTTPS đã chạy ổn định. Đang thử nghiệm thì đặt tạm
`stsSeconds: 0`.

---

## Tóm tắt lệnh hay dùng

```bash
cd ~/claude-vps

# Triển khai lần đầu
bash scripts/setup.sh

# Đổi mật khẩu
bash scripts/setup.sh --regen-auth

# Sao lưu
bash scripts/backup.sh

# Theo dõi
docker compose ps
docker compose logs -f claude-code
docker logs -f traefik            # Traefik KHÔNG thuộc stack này -> dùng docker logs
docker stats --no-stream

# Khởi động lại / cập nhật
docker compose restart
docker compose up -d --build

# Vào shell của container
docker compose exec claude-code bash
docker compose exec claude-code claude --version

# 🚨 KHÔNG BAO GIỜ gõ lệnh này trừ khi muốn xoá sạch:
# docker compose down -v
```
