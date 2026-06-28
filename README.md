# Pterodactyl Manager

Script Bash satu-file untuk install, update, backup, monitoring, dan repair **Pterodactyl Panel + Wings** di server Ubuntu/Debian. Cocok untuk VPS tanpa IP publik (mode Cloudflare Tunnel) maupun server publik (mode Let's Encrypt).

> Versi script: **V7.3.3** &nbsp;|&nbsp; OS target: Ubuntu 20.04/22.04/24.04, Debian 11/12 &nbsp;|&nbsp; Harus dijalankan sebagai **root** &nbsp;|&nbsp; Struktur modular di `modules/` &nbsp;|&nbsp; Error code standar (`E_SUCCESS`–`E_LOCKED`) &nbsp;|&nbsp; Fitur baru: Addon Manager + Panel Domain management, S3 Backup with auto, pre-update backup, Migrasi, Auto Update

## Changelog

### V7.3.3 (latest) — Wings config selective backup
- **FIX: `wings_config` backup sekarang hanya `config.yml`** (sebelumnya `cp -a` copy seluruh isi `/etc/pterodactyl/` termasuk file runtime)
- Lokal: pakai `_copy_wings_config()` dengan whitelist `config.yml`/`config.yaml` saja
- S3: zip dengan `-x` untuk exclude runtime files (`*.sock`, `*.tmp`, `*.log`, `*.lock`, `*.pid`, `*.swp`) + cert files (`*.pem`, `*.crt`, `*.key`, `ssl/*`)
- Berlaku untuk `backup_system_with_password`, `backup_to_s3`, dan `auto_backup_s3`
- **FIX: `_addon_uninstall_phpmyadmin`** (typo: function di-define dengan nama `_addon_install_phpmyadmin` kedua kali → menu #15 error)
- Tambah `_zip_create()` helper: trap `SIGINT`/`SIGTERM` + `unzip -tq` integrity check setelah zip
- Exclude `storage/framework/{cache,sessions,views}` dari panel zip (size -50-200MB, no functionality loss)
- UI: `header()` rewrite (box-drawing modern + system status dashboard), `print_section()`, `print_footer()`

### V7.3.2 — Panel Domain fix
- **FIX: `backup.meta` default `localhost`** — backup sekarang pre-check `PANEL_DOMAIN`, auto-detect dari nginx, prompt di interactive mode, validate format
- **NEW: Menu `Set Panel Domain`** (Management #12) — set manual + validate + save
- **NEW: Menu `Fix Backup Domain`** (Backup #19) — rewrite `backup.meta` di backup existing (1 / semua / scan yang perlu di-fix)
- **NEW: Pre-restore warning** — kalau `backup.meta` domain = `localhost`/kosong, tanya konfirmasi sebelum lanjut
- **Auto S3 backup** skip kalau `PANEL_DOMAIN` gak valid (dengan notifikasi ke Telegram/Discord)

### V7.3.1 — Backup hardening
- **Disk space pre-flight** — tolak backup kalau free < `BACKUP_MIN_DISK_GB` (default 2GB, set 0 untuk skip)
- **Compression level** — `BACKUP_COMPRESSION_LEVEL` (1-9, default 6) diteruskan ke `zip -${lvl}`
- **S3 integrity verify** — `s3_verify_backup` download ulang sample file, compare size + `unzip -tq` untuk detect corruption
- **Auto-backup S3 terjadwal** — flag `--auto-s3-backup` di cron, optional saat setup auto-backup
- **Auto-backup sebelum update panel/wings** — `AUTO_BACKUP_BEFORE_UPDATE` toggle (default ON), pakai `AUTO_BACKUP_CNF` untuk password
- **Menu `Set Backup Options`** — ubah disk min, compression level, toggle pre-update backup

### V7.3 — Addon Manager overhaul
- **FIX: `$SCRIPT_DIR` undefined** — script root auto-detect dari `BASH_SOURCE`, addon folder selalu ketemu
- **FIX: zip integrity check** — `unzip -tq` sebelum extract, tolak addon korup
- **FIX: phpMyAdmin uninstall** menu (sebelumnya cuma install)
- **NEW: Search/Filter addon list** — substring case-insensitive
- **NEW: Info addon** — size, integrity, files count, panel/frontend/migration flags, kompatibilitas, preview instruksi
- **NEW: Export/Import addon state** (JSON) — clone addon setup ke server lain
- **NEW: Bulk install/uninstall** — pilih banyak (`1,3,5` atau `1-3` atau `all`)
- **NEW: Diff installed vs available** — lihat apa yang belum terinstall
- **NEW: Reinstall semua** — install ulang semua addon terinstall

### V7.2.1
- FIX verify_backup & cleanup_orphan_backups pakai extension `.zip` (sebelumnya `.tar.gz`)
- FIX S3 restore wings_config (extract zip → folder)
- FIX S3 restore lock + tambah menu List/Hapus/Prune S3 + section S3 di backup_stats
- NEW s3_prune_old_backups untuk retention S3

### V7.2
- S3 backup include `server_volumes.zip` sesuai toggle `S3_INCLUDE_VOLUMES`
- Safety guard: backup volumes ke S3 minta konfirmasi kalau >10GB
- `backup_to_s3()` upload `backup.meta`; `s3_restore_backup()` download volumes + meta
- Konsistensi: empty-file check + info size/duration di S3 backup

---

## Changelog

(Catatan: section Changelog di atas adalah yang terbaru. Versi lebih lama di bawah.)

### V7.1
- Addon Manager (27+ addon), Remote Wings Installer, Egg Manager, Migrasi server, Auto Update

---

## Struktur Modular

Script ini telah dipecah menjadi modul-modul fitur di folder `modules/`:

| File | Fungsi |
|------|--------|
| `ptero.sh` | Entrypoint utama — source semua modul + menu interaktif |
| `modules/config.sh` | Variabel konfigurasi & persistensi |
| `modules/helpers.sh` | Fungsi bantu (logging, lock, notifikasi, MySQL, dll.) |
| `modules/install.sh` | Install panel, wings, dependencies, Nginx, database |
| `modules/update.sh` | Update panel, wings, deep maintenance |
| `modules/backup.sh` | Backup & restore lengkap + auto-backup terjadwal |
| `modules/cloudflare.sh` | Cloudflare Tunnel, deploy mode, Let's Encrypt, fail2ban, firewall |
| `modules/monitoring.sh` | Health check, info sistem, log realtime, backup statistik |
| `modules/management.sh` | Manajemen user/DB panel, bulk action, list admin |
| `modules/optimize.sh` | Optimasi server kecil, tuning PHP/DB/Redis, swap |
| `modules/repair.sh` | Repair permission, nginx, queue, Redis, Wings, network |
| `modules/features.sh` | Fitur lanjutan: Telegram, watchdog, security audit, help |
| `modules/extras.sh` | Fitur tambahan: verify backup, container stats, cache, dll. |
| `modules/uninstall.sh` | Deep uninstall total |
| `modules/remote-node.sh` | Remote Wings Installer via SSH |
| `modules/eggs.sh` | Egg Manager (import/list/update dari repo) |
| `modules/migration.sh` | Server Migration Tool (pindah antar node) |

## Daftar Isi

- [Fitur Utama](#fitur-utama)
- [Persyaratan](#persyaratan)
- [Cara Pakai](#cara-pakai)
- [Daftar Menu Lengkap](#daftar-menu-lengkap)
- [Mode Deploy: Tunnel vs Public](#mode-deploy-tunnel-vs-public)
- [Backup & Restore](#backup--restore)
- [Notifikasi (Telegram & Discord)](#notifikasi-telegram--discord)
- [File Penting](#file-penting)
- [Troubleshooting](#troubleshooting)
- [Keamanan](#keamanan)
- [Disclaimer](#disclaimer)

---

## Fitur Utama

- **Install otomatis**: Panel + Wings, atau install terpisah (panel-only / wings-only)
- **Update aman**: panel update dengan trap auto-recover dari maintenance mode + verifikasi tarball
- **Backup & Restore lengkap**: database, panel files, wings config, server volumes, retention otomatis, checksum SHA256
- **Cloudflare Tunnel**: Connector token (cepat) atau Named Tunnel (full control)
- **Let's Encrypt**: HTTPS otomatis untuk mode public IP
- **Cloudflare Origin Cert**: untuk Full (Strict) mode di tunnel
- **Monitoring**: health check, info sistem, log realtime, cek koneksi Wings, security audit
- **Repair tools**: nginx config, queue worker, redis, wings service, network reset, dll.
- **Manajemen panel**: buat user/admin, reset password, ganti DB password, bulk action server, manajemen user
- **Notifikasi**: Telegram & Discord webhook
- **Watchdog Wings**: auto-restart saat Wings crash
- **Optimasi**: tuning untuk mesin kecil (PHP, MariaDB, Redis), swap creator
- **Self-update + rollback**: script bisa update sendiri dan rollback ke `.bak`

### Fitur Tambahan (V5.4+)

| Menu | Fitur | Kegunaan |
|------|-------|----------|
| 52 | Verify Backup Integrity | Cek backup tidak korup sebelum kepepet restore |
| 53 | List Admin Users | Audit cepat siapa yang punya akses admin + status 2FA |
| 54 | Live Container Stats | CPU/RAM/Disk per server Pterodactyl, top 5 boros |
| 55 | Clear Panel Cache | Fix umum: panel error setelah update / edit `.env` |
| 56 | Auto-Fix Panel | One-click panel doctor: perm + cache + restart + HTTP test |
| 57 | Cleanup Orphan Backups | Hapus backup yang gagal di tengah / partial |
| 58 | Drop & Reset Database | Reset bersih DB panel (auto-backup wajib dulu) |
| 59 | Flush Redis Cache | Fix session/queue stuck |
| 60 | Prune Old Backups Now | Aplikasikan retention manual, tidak nunggu cron |

---

## Persyaratan

- **OS**: Ubuntu 20.04 / 22.04 / 24.04, atau Debian 11 / 12
- **Akses**: root (atau user dengan sudo penuh)
- **RAM minimum**: 1 GB (rekomendasi 2 GB+ untuk panel + wings di 1 mesin)
- **Disk**: 10 GB+ free
- **Akses jaringan**: keluar ke `github.com`, `getcomposer.org`, `packages.sury.org`, `download.docker.com`
- **Untuk mode tunnel**: akun Cloudflare (gratis cukup)
- **Untuk mode public**: domain + DNS A-record yang mengarah ke IP server

---

## Cara Pakai

Jalankan script tanpa argumen untuk masuk ke menu interaktif:

```bash <(curl -s https://raw.githubusercontent.com/aldixyz331/ptero-manager/refs/heads/main/ptero.sh)
```

### Skenario umum

**A. Install panel + wings di 1 server (mode tunnel, paling mudah)**
1. Menu **47** → pilih `tunnel`
2. Menu **1** → Full Install
3. Menu **8** → Setup Cloudflare Named Tunnel (login Cloudflare via browser)
4. Menu **10** → Generate Wings config dari Panel API
5. `systemctl start wings`

**B. Install di server publik dengan HTTPS asli**
1. Pastikan DNS A-record domain sudah arah ke IP server
2. Menu **47** → pilih `public`
3. Menu **1** → Full Install
4. Menu **48** → Setup HTTPS Let's Encrypt
5. Menu **49** → Setup Fail2ban (opsional, sangat direkomendasikan)

**C. Backup berkala otomatis**
1. Menu **16** → Backup Otomatis Terjadwal (set jam, mis. `02:30`)
2. Menu **41** → Statistik Backup untuk monitor
3. Menu **52** → Verify Backup Integrity sesekali untuk pastikan backup masih sehat

**D. Panel error / blank / 500**
1. Menu **55** → Clear Panel Cache (fix paling umum)
2. Kalau masih: Menu **56** → Auto-Fix Panel
3. Kalau masih: Menu **17** → Health Check + Menu **19** → lihat log

### Argumen CLI

| Flag | Fungsi |
|------|--------|
| `--self-check` | Cek sintaks + ketersediaan semua fungsi tanpa run menu |
| `--auto-backup [--cnf <path>]` | Mode dipakai cron untuk auto-backup tak interaktif |
| `--quiet` | Kurangi output verbose |

---

## Daftar Menu Lengkap

```
--- INSTALL & UPDATE ---
1)  Full Install Panel + Wings
2)  Update Panel
3)  Update Wings Saja
4)  Provision Web & Services
5)  Deep Maintenance
6)  Cek Update Script (self-update)

--- CLOUDFLARE TUNNEL ---
7)  Setup Cloudflare Connector Token
8)  Setup Cloudflare Named Tunnel
9)  Set Domain Panel Cloudflare
10) Generate Wings config.yml dari Panel API

--- BACKUP & RESTORE ---
11) Backup System Lengkap (Local + Cloud)
12) Backup Database Saja
13) Restore dari Backup (pilih nomor)
14) List Backup
15) Hapus Backup (pilih nomor)
16) Backup Otomatis Terjadwal

--- MONITORING ---
17) Health Check Service
18) Informasi Sistem Lengkap
19) Lihat Log Real-time
20) Cek Koneksi Wings ke Panel
21) Setup/Test Discord Webhook

--- MANAJEMEN ---
22) Buat User/Admin Panel
23) Reset Password Admin
24) Ganti Password Database
25) Maintenance Mode Panel
26) Export Konfigurasi
27) Manajemen User Panel (list/edit/hapus)
28) Bulk Action Server (suspend/restart all)

--- SERVER & REPAIR ---
29) Repair Menu Lengkap
30) Setup UFW Firewall
31) Setup Rclone Cloud Storage
32) Create Swap File
33) Optimasi Server Kecil
34) Restart Semua Service
35) Security Audit
36) Optimasi Database (OPTIMIZE TABLE)
37) Setup Wings Watchdog (auto-restart)
38) Hapus Wings Watchdog

--- LANJUTAN V5.4 ---
39) Setup Telegram Notifikasi
40) Set Custom Banner
41) Statistik Backup
42) Rollback Script (.bak)
43) Bantuan / Help

--- INSTALL TERPISAH ---
45) Install Panel Saja (tanpa Wings)
46) Install Wings Saja (node terpisah)

--- MODE DEPLOY (tunnel / public IP) ---
47) Pilih Mode Deploy
48) Setup HTTPS Let's Encrypt (mode public)
49) Setup Fail2ban
50) Status Fail2ban
51) Pasang Cloudflare Origin Cert (mode tunnel, Full Strict)

--- FITUR TAMBAHAN ---
52) Verify Backup Integrity
53) List Admin Users
54) Live Container Stats
55) Clear Panel Cache
56) Auto-Fix Panel
57) Cleanup Orphan Backups
59) Flush Redis Cache
60) Prune Old Backups Now

--- FITUR BARU V6.0 ---
61) Remote Wings Installer (install via SSH)
62) Cek Status Wings Remote
63) Egg Manager (import/list/update eggs)
64) Setup S3 Backup Destination
65) Backup & Upload ke S3
66) Server Migration Tool (pindah node)
67) Cek Update Keamanan (Panel & Wings)
68) Setup Auto Security Updates

--- DESTRUCTIVE ---
58) Drop & Reset Database Panel
44) Deep Uninstall (Hapus Bersih)
0)  Keluar
```

---

## Mode Deploy: Tunnel vs Public

| Aspek | Tunnel (default) | Public |
|-------|------------------|--------|
| Butuh IP publik | Tidak | Ya |
| Butuh domain | Disarankan | Wajib |
| TLS | Cloudflare (atau Origin Cert) | Let's Encrypt langsung |
| Port 80/443 dibuka di UFW | Tidak (loopback only) | Ya |
| Setup cert | Otomatis di CF / menu 51 | Menu 48 |
| Cocok untuk | VPS murah / home server / NAT | Server cloud konvensional |

Ganti mode lewat menu **47**. Script akan otomatis sync `TRUSTED_PROXIES` di `.env` dan regenerate config Nginx.

---

## Backup & Restore

### Struktur folder backup

```
/root/backup/
└── ptero_2026-04-23_02-30-00/
    ├── panel_db.sql            # mysqldump
    ├── panel_files.tar.gz      # /var/www/pterodactyl
    ├── wings_config/           # /etc/pterodactyl
    ├── server_volumes.tar.gz   # /var/lib/pterodactyl/volumes (opsional)
    └── CHECKSUMS.sha256        # untuk verifikasi integritas
```

### Retention

- **Hari**: `BACKUP_RETENTION_DAYS=7` (default)
- **Jumlah max**: `BACKUP_MAX_COUNT=10` (default)
- Auto-prune jalan setiap kali backup baru dibuat
- Manual prune sekarang: menu **60**

### Backup ke cloud (opsional)

Menu **31** untuk setup `rclone` ke Google Drive / OneDrive / S3 / dll. Setelah dikonfigurasi, backup otomatis di-upload ke remote.

### Restore

Menu **13** → pilih backup → pilih komponen yang mau di-restore (lengkap / DB saja / panel saja / wings saja / volumes saja). Service akan otomatis di-stop saat restore dan di-start kembali, dengan rollback otomatis kalau gagal di tengah.

---

## Notifikasi (Telegram & Discord)

### Telegram (menu 39)
1. Buat bot via [@BotFather](https://t.me/BotFather), salin token
2. Kirim `/start` ke bot, lalu cek `https://api.telegram.org/bot<TOKEN>/getUpdates` untuk dapat Chat ID
3. Menu **39** → masukkan token & chat ID → test kirim

### Discord (menu 21)
1. Server settings → Integrations → Webhooks → New Webhook → copy URL
2. Menu **21** → tempel URL → test kirim

Notifikasi dikirim untuk: backup sukses/gagal, install/update selesai, panel di-fix, drop database, peringatan disk penuh, backup korup, dll.

---

## File Penting

| Path | Isi |
|------|-----|
| `/etc/ptero-manager/manager.conf` | Konfigurasi script (DB, Telegram, Discord, deploy mode, retention) |
| `/etc/ptero-manager/auto-backup.cnf` | Kredensial DB untuk auto-backup cron (mode 600, root-only) |
| `/var/log/ptero-manager.log` | Log aktivitas script (di-rotate weekly) |
| `/usr/local/sbin/ptero-auto-backup.sh` | Wrapper auto-backup yang dipanggil cron |
| `/etc/cron.d/ptero-manager-backup` | Jadwal cron auto-backup |
| `/var/www/pterodactyl` | Default panel directory (`PANEL_DIR`) |
| `/etc/pterodactyl` | Default Wings directory (`WINGS_DIR`) |
| `/root/backup` | Default backup root (`BACKUP_ROOT`) |

---

## Troubleshooting

### "Panel blank / error 500 setelah update"
1. Menu **55** (Clear Panel Cache)
2. Menu **56** (Auto-Fix Panel) — jalankan urut perm + cache + restart + test
3. Cek log: menu **19** opsi 4 (Log Panel Laravel)

### "Wings tidak bisa connect ke panel"
- Menu **20** (Cek Koneksi Wings ke Panel)
- Pastikan token di `/etc/pterodactyl/config.yml` masih valid (regenerate via menu **10**)
- Kalau panel di belakang Cloudflare: `TRUSTED_PROXIES=*` harus di `.env`

### "Login sebentar lalu kelogout / queue stuck"
- Menu **59** (Flush Redis Cache) — flush DB 0 dulu, kalau masih FLUSHALL

### "Backup pasti korup"
- Menu **52** (Verify Backup Integrity) — pilih opsi 2 untuk scan semua
- Kalau banyak korup, cek disk: menu **17** (Health Check) → bagian "Disk & RAM"

### "Disk penuh"
- Menu **41** (Statistik Backup) untuk lihat ukuran
- Menu **57** (Cleanup Orphan Backups) untuk hapus backup gagal
- Menu **60** (Prune Old Backups Now) untuk paksa retention

### "Lupa password admin"
- Menu **23** (Reset Password Admin)

### "Update script broken"
- Menu **42** (Rollback Script) — kembali ke versi sebelum self-update

---

## Keamanan

- **Password DB** divalidasi (min 8 char, tolak whitespace & quote)
- **Kredensial MySQL** disimpan ke temp `.cnf` (mode 600), tidak pernah lewat command line / process list
- **Auto-backup cron** baca password dari file mode 600 (`/etc/ptero-manager/auto-backup.cnf`)
- **Backup pra-drop database** wajib dibuat sebelum operasi destructive (menu 58)
- **Lock file** (`flock`-based) mencegah backup/install/update jalan bersamaan
- **Restore atomic**: kalau gagal di tengah, service yang di-stop otomatis di-start lagi
- **Self-signed cert** otomatis untuk mode tunnel kalau belum pasang Origin Cert
- **UFW preset** sesuai mode deploy (loopback-only untuk tunnel, public untuk public)
- **Fail2ban preset** untuk SSH + Nginx (menu 49)
- **Security audit**: menu 35 untuk cek perm `.env`, password length, SSH config, dll.

> **Tips**: aktifkan 2FA untuk semua admin (lihat menu 53 untuk audit). Pakai mode `tunnel` kalau tidak butuh IP publik — lebih aman karena port tidak ke-expose.

---

## Disclaimer

100% buatan AI kalo error fix sendiri. mau pakai atau ga terserah

Script ini disediakan **as-is**, tanpa garansi. Selalu **backup dulu** sebelum operasi destructive (menu 1, 2, 13, 44, 58). Jalankan di server test dulu kalau belum yakin.

Pterodactyl Panel & Wings adalah trademark dari [Pterodactyl Software](https://pterodactyl.io). Script ini tidak berafiliasi resmi.
