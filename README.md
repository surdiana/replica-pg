# Pengaturan Replikasi PostgreSQL Master-Replica

Repositori ini berisi skrip untuk mengatur replikasi PostgreSQL dengan node master dan replica menggunakan Docker. Pengaturan ini dirancang untuk replikasi antar-server dengan opsi konfigurasi yang fleksibel.

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
| `REPLICATION_USER` | `replica` | Pengguna untuk koneksi replikasi |
| `REPLICATION_PASSWORD` | `replica` | Kata sandi untuk pengguna replikasi |
| `POSTGRES_VERSION` | `15` | Versi PostgreSQL yang digunakan |
| `CONTAINER_NAME` | `postgres_replica` | Nama untuk container Docker |
| `REPLICA_PORT` | `5433` | Port untuk PostgreSQL replica |
| `MASTER_HOST` | `192.168.2.77` | **WAJIB**: Alamat IP server master |
| `MASTER_PORT` | `5432` | Port server PostgreSQL master |

## Instruksi Pengaturan

### 1. Pengaturan Server Master

1. Clone repositori ini di server master:
   ```
   git clone https://github.com/username-anda/replica-pg.git
   cd replica-pg
   ```

2. Konfigurasi variabel lingkungan jika diperlukan (atau gunakan default):
   ```
   export IP_BINDINGS=("192.168.2.77:5432")
   export PG_HBA_ALLOWED_IPS=("192.168.2.77/32" "ip_server_replica/32")
   ```

   > **Penting**: Pastikan untuk menyertakan IP server replica di `PG_HBA_ALLOWED_IPS` untuk mengizinkan koneksi replikasi.

3. Jalankan skrip pengaturan master:
   ```
   chmod +x setup-master.sh
   ./setup-master.sh
   ```

4. Verifikasi pengaturan master:
   ```
   docker logs postgres_master
   ```

5. Catat alamat IP master untuk digunakan dalam pengaturan replica.

### 2. Pengaturan Server Replica

1. Clone repositori ini di server replica:
   ```
   git clone https://github.com/username-anda/replica-pg.git
   cd replica-pg
   ```

2. Konfigurasi variabel lingkungan, pastikan untuk mengatur IP server master:
   ```
   export MASTER_HOST=192.168.2.77  # Ganti dengan IP master yang sebenarnya
   export MASTER_PORT=5432
   ```

3. Jalankan skrip pengaturan replica:
   ```
   chmod +x setup-replica.sh
   ./setup-replica.sh
   ```

4. Verifikasi pengaturan replica dan status replikasi:
   ```
   docker logs postgres_replica
   ```

## Verifikasi

### Di Master

Periksa slot replikasi dan replica yang terhubung:
```
docker exec postgres_master psql -U postgres -c "SELECT * FROM pg_replication_slots;"
docker exec postgres_master psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Di Replica

Verifikasi bahwa replica berada dalam mode recovery dan periksa lag replikasi:
```
docker exec postgres_replica psql -U postgres -c "SELECT pg_is_in_recovery();"
docker exec postgres_replica psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

## Pengujian Replikasi

1. Buat database uji di master:
   ```
   docker exec postgres_master psql -U postgres -c "CREATE DATABASE testdb;"
   ```

2. Buat tabel uji dan masukkan data:
   ```
   docker exec postgres_master psql -U postgres -d testdb -c "CREATE TABLE test_table (id SERIAL PRIMARY KEY, name TEXT);"
   docker exec postgres_master psql -U postgres -d testdb -c "INSERT INTO test_table (name) VALUES ('test1'), ('test2');"
   ```

3. Verifikasi bahwa data direplikasi ke replica:
   ```
   docker exec postgres_replica psql -U postgres -d testdb -c "SELECT * FROM test_table;"
   ```

## Pemecahan Masalah

### Masalah Master

- **Masalah konektivitas**: Pastikan aturan firewall mengizinkan koneksi pada port PostgreSQL
- **Masalah slot replikasi**: Periksa apakah slot replikasi ada
  ```
  docker exec postgres_master psql -U postgres -c "SELECT * FROM pg_replication_slots;"
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

## Pertimbangan Keamanan

- Konfigurasi default menggunakan kata sandi yang tidak aman. Untuk produksi, gunakan kata sandi yang kuat.
- Pertimbangkan untuk menggunakan SSL untuk enkripsi antara master dan replica.
- Batasi akses jaringan menggunakan aturan firewall untuk meningkatkan keamanan.

## Pemeliharaan

### Backup

Buat backup rutin dari master:
```
docker exec postgres_master pg_dump -U postgres database_anda > backup.sql
```

### Pemantauan

Pantau lag replikasi secara teratur:
```
docker exec postgres_replica psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

## Konfigurasi Lanjutan

Untuk pengaturan lanjutan, Anda dapat memodifikasi:
- Konfigurasi `pg_hba.conf` di kedua skrip
- Pengaturan jaringan Docker
- Parameter kinerja PostgreSQL