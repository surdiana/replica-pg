# Pengaturan Replikasi PostgreSQL Master-Replica dengan Database Kustom

Repositori ini berisi skrip untuk mengatur replikasi PostgreSQL dengan node master dan replica menggunakan Docker. Pengaturan ini dirancang untuk replikasi antar-server dengan opsi konfigurasi yang fleksibel dan mendukung nama database kustom.

## Prasyarat

- Docker dan Docker Compose terinstal di kedua server
- Konektivitas jaringan antara server master dan replica
- Pengetahuan dasar tentang konsep replikasi PostgreSQL

## Variabel Konfigurasi

### Variabel Server Master

Variabel dapat dikonfigurasi sebagai variabel lingkungan sebelum menjalankan skrip pengaturan:

| Variabel | Default | Deskripsi |
|----------|---------|-------------|
| `ARCHIVE_PATH` | `./archive` | Direktori untuk file arsip WAL |
| `DATA_PATH` | `./pg_data` | Direktori untuk file data PostgreSQL |
| `POSTGRES_USER` | `postgres` | Pengguna utama PostgreSQL |
| `POSTGRES_PASSWORD` | `postgres` | Kata sandi untuk pengguna utama PostgreSQL |
| `POSTGRES_DB` | `postgres` | Nama database kustom (baru) |
| `REPLICATION_USER` | `replica` | Pengguna untuk koneksi replikasi |
| `REPLICATION_PASSWORD` | `replica` | Kata sandi untuk pengguna replikasi |
| `POSTGRES_VERSION` | `15` | Versi PostgreSQL yang digunakan |
| `CONTAINER_NAME` | `postgres_master` | Nama untuk container Docker |
| `IP_BINDINGS` | `192.168.2.77:5432` | Array binding IP:port (penting untuk akses antar-server) |
| `PG_HBA_ALLOWED_IPS` | `192.168.2.77/32` | Array alamat IP/jaringan yang diizinkan untuk terhubung |

### Variabel Server Replica

| Variabel | Default | Deskripsi |
|----------|---------|-------------|
| `ARCHIVE_PATH` | `./archive` | Direktori untuk file arsip WAL |
| `DATA_PATH` | `./replica_data` | Direktori untuk file data PostgreSQL |
| `POSTGRES_USER` | `postgres` | Pengguna utama PostgreSQL |
| `POSTGRES_PASSWORD` | `postgres` | Kata sandi untuk pengguna utama PostgreSQL |
| `POSTGRES_DB` | `postgres` | Nama database kustom (baru) |
| `REPLICATION_USER` | `replica` | Pengguna untuk koneksi replikasi |
| `REPLICATION_PASSWORD` | `replica` | Kata sandi untuk pengguna replikasi |
| `POSTGRES_VERSION` | `15` | Versi PostgreSQL yang digunakan |
| `CONTAINER_NAME` | `postgres_replica` | Nama untuk container Docker |
| `REPLICA_PORT` | `5433` | Port untuk PostgreSQL replica |
| `MASTER_HOST` | `192.168.2.77` | **WAJIB**: Alamat IP server master |
| `MASTER_PORT` | `5432` | Port server PostgreSQL master |

## Fitur Database Kustom

Pengaturan ini mendukung penggunaan nama database kustom melalui variabel `POSTGRES_DB`. Ketika Anda mengatur variabel ini, skrip akan:

1. Membuat database dengan nama yang ditentukan pada server master
2. Mengonfigurasi hak akses yang tepat di pg_hba.conf untuk database kustom
3. Membuat tabel uji dalam database kustom untuk memverifikasi replikasi
4. Memastikan database kustom direplikasi ke server replica

Fitur ini memungkinkan Anda untuk langsung menggunakan nama database aplikasi Anda tanpa perlu langkah tambahan setelah penyiapan.

## Instruksi Pengaturan

### 1. Pengaturan Server Master

1. Clone repositori ini di server master:
   ```
   git clone https://github.com/username-anda/replica-pg.git
   cd replica-pg
   ```

2. Konfigurasi variabel lingkungan jika diperlukan (atau gunakan default):
   ```
   export POSTGRES_DB="mydatabase"  # Setel nama database kustom Anda
   export IP_BINDINGS=("192.168.2.77:5432")
   export PG_HBA_ALLOWED_IPS=("192.168.2.77/32" "ip_server_replica/32")
   ```

   > **Penting**: Pastikan untuk menyertakan IP server replica di `PG_HBA_ALLOWED_IPS` untuk mengizinkan koneksi replikasi.

3. Jalankan skrip pengaturan master:
   ```
   chmod +x setup-master.sh
   ./setup-master.sh
   ```

4. Verifikasi pengaturan master dan database kustom:
   ```
   docker logs postgres_master
   docker exec postgres_master psql -U postgres -c "\l" | grep mydatabase
   ```

5. Catat alamat IP master untuk digunakan dalam pengaturan replica.

### 2. Pengaturan Server Replica

1. Clone repositori ini di server replica:
   ```
   git clone https://github.com/username-anda/replica-pg.git
   cd replica-pg
   ```

2. Konfigurasi variabel lingkungan, pastikan untuk mengatur IP server master dan nama database yang sama:
   ```
   export MASTER_HOST=192.168.2.77  # Ganti dengan IP master yang sebenarnya
   export MASTER_PORT=5432
   export POSTGRES_DB="mydatabase"  # HARUS SAMA dengan yang diatur di master
   ```

3. Jalankan skrip pengaturan replica:
   ```
   chmod +x setup-replica.sh
   ./setup-replica.sh
   ```

4. Verifikasi pengaturan replica dan status replikasi:
   ```
   docker logs postgres_replica
   docker exec postgres_replica psql -U postgres -c "\l" | grep mydatabase
   ```

## Verifikasi

### Di Master

Periksa slot replikasi dan replica yang terhubung:
```
docker exec postgres_master psql -U postgres -d $POSTGRES_DB -c "SELECT * FROM pg_replication_slots;"
docker exec postgres_master psql -U postgres -d $POSTGRES_DB -c "SELECT * FROM pg_stat_replication;"
```

Periksa tabel uji yang dibuat otomatis:
```
docker exec postgres_master psql -U postgres -d $POSTGRES_DB -c "SELECT * FROM replication_test;"
```

### Di Replica

Verifikasi bahwa replica berada dalam mode recovery dan periksa lag replikasi:
```
docker exec postgres_replica psql -U postgres -d $POSTGRES_DB -c "SELECT pg_is_in_recovery();"
docker exec postgres_replica psql -U postgres -d $POSTGRES_DB -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

Periksa tabel uji yang direplikasi:
```
docker exec postgres_replica psql -U postgres -d $POSTGRES_DB -c "SELECT * FROM replication_test;"
```

## Pengujian Replikasi

1. Tambahkan data uji di master:
   ```
   docker exec postgres_master psql -U postgres -d $POSTGRES_DB -c "INSERT INTO replication_test (test_name) VALUES ('test from readme');"
   ```

2. Verifikasi bahwa data direplikasi ke replica:
   ```
   docker exec postgres_replica psql -U postgres -d $POSTGRES_DB -c "SELECT * FROM replication_test;"
   ```

## Pemecahan Masalah

### Masalah Master

- **Masalah konektivitas**: Pastikan aturan firewall mengizinkan koneksi pada port PostgreSQL
- **Masalah slot replikasi**: Periksa apakah slot replikasi ada
  ```
  docker exec postgres_master psql -U postgres -d $POSTGRES_DB -c "SELECT * FROM pg_replication_slots;"
  ```
- **Masalah database kustom**: Periksa apakah database kustom dibuat
  ```
  docker exec postgres_master psql -U postgres -c "\l" | grep $POSTGRES_DB
  ```

### Masalah Replica

- **Error koneksi**: Verifikasi bahwa replica dapat mencapai master
  ```
  nc -z -v ip_master port_master
  ```
- **Replikasi streaming tidak berfungsi**: Periksa log replica
  ```
  docker logs postgres_replica
  ```
- **Masalah izin**: Pastikan pg_hba.conf master menyertakan IP replica
- **Database kustom tidak direplikasi**: Pastikan nama database sama di master dan replica
  ```
  docker exec postgres_replica psql -U postgres -c "\l" | grep $POSTGRES_DB
  ```

## Pertimbangan Keamanan

- Konfigurasi default menggunakan kata sandi yang tidak aman. Untuk produksi, gunakan kata sandi yang kuat.
- Pertimbangkan untuk menggunakan SSL untuk enkripsi antara master dan replica.
- Batasi akses jaringan menggunakan aturan firewall untuk meningkatkan keamanan.

## Pemeliharaan

### Backup

Buat backup rutin dari database kustom:
```
docker exec postgres_master pg_dump -U postgres $POSTGRES_DB > backup.sql
```

### Pemantauan

Pantau lag replikasi secara teratur:
```
docker exec postgres_replica psql -U postgres -d $POSTGRES_DB -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

## Konfigurasi Lanjutan

Untuk pengaturan lanjutan, Anda dapat memodifikasi:
- Konfigurasi `pg_hba.conf` di kedua skrip
- Pengaturan jaringan Docker
- Parameter kinerja PostgreSQL
- Struktur dan indeks database kustom melalui script migrasi

## Pemulihan Bencana

Untuk mempromosikan replica menjadi master baru jika master utama gagal:

1. Hentikan proses replikasi di replica:
   ```
   docker exec postgres_replica psql -U postgres -c "SELECT pg_promote();"
   ```

2. Pastikan database kustom tersedia dan siap digunakan:
   ```
   docker exec postgres_replica psql -U postgres -d $POSTGRES_DB -c "SELECT 1;"
   ```

3. Konfigurasikan aplikasi Anda untuk menggunakan alamat dan port replica sebagai database utama.