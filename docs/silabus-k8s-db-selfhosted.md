# Silabus: Kubernetes + Database Self-Hosted (ClickHouse, MongoDB, PostgreSQL) + Migrasi Supabase

**Durasi:** ~16 minggu (asumsi 10–15 jam/minggu)
**Format:** hands-on. Setiap fase punya lab wajib dan kriteria kelulusan.
**Target akhir:** kamu bisa menjalankan tiga database production-grade di Kubernetes, dan memindahkan aplikasi dari Supabase ke infrastruktur sendiri tanpa kehilangan data.

---

## Sebelum Mulai: Baca Ini Dulu

Tiga hal yang jujur perlu kamu tahu sebelum investasi 16 minggu:

**1. Database di Kubernetes itu bukan default yang benar untuk semua orang.** K8s dirancang untuk workload stateless. Menjalankan Postgres di atasnya menambah lapisan kegagalan (CNI, CSI, scheduler, kubelet) di antara aplikasimu dan disk. Ini masuk akal kalau kamu: sudah punya cluster K8s, punya banyak database, butuh standarisasi ops, atau memang ingin menguasai skill-nya. Ini tidak masuk akal kalau kamu cuma punya satu Postgres dan tujuan utamamu adalah "lepas dari Supabase" — VM biasa dengan Postgres + pgBackRest jauh lebih sederhana dan lebih mudah di-debug jam 3 pagi.

**2. Total cost of ownership itu nyata.** Supabase menagihmu uang; self-hosting menagihmu waktu. Backup yang diverifikasi, patching, monitoring, on-call, upgrade mayor — semuanya jadi tanggung jawabmu.

**3. Migrasi Supabase bukan migrasi Postgres.** Supabase adalah Postgres + PostgREST + GoTrue (auth) + Realtime + Storage API + Kong + Studio + Edge Functions. Memindahkan Postgres-nya itu bagian yang mudah. Bagian sulitnya adalah semua yang di atasnya. Fase 7 membahas ini secara khusus.

Kalau setelah membaca ini kamu tetap lanjut — bagus, silabusnya di bawah.

---

## Peta Fase

| Fase | Topik | Durasi |
|---|---|---|
| 0 | Prasyarat | 1 minggu |
| 1 | Kubernetes fundamental | 3 minggu |
| 2 | Stateful workload & storage | 2 minggu |
| 3 | PostgreSQL di Kubernetes | 3 minggu |
| 4 | MongoDB di Kubernetes | 1.5 minggu |
| 5 | ClickHouse di Kubernetes | 2 minggu |
| 6 | Operasional Day-2 | 1.5 minggu |
| 7 | Migrasi Supabase → self-hosted | 2 minggu |
| 8 | Capstone | 1 minggu |

---

## Lab Environment

Siapkan dua lingkungan sejak awal. Jangan belajar hanya di laptop.

**Lokal (untuk iterasi cepat):**
- `kind` atau `k3d` — multi-node cluster di Docker
- Minimal 16 GB RAM di mesin lokal (ClickHouse + Postgres + Mongo bersamaan itu lapar)

**Remote (untuk realisme):**
- 3 VPS kecil (2 vCPU / 4 GB / 80 GB SSD) — Hetzner, Contabo, atau Biznet/IDCloudHost kalau butuh latency Indonesia
- Install `k3s` (bukan managed) supaya kamu merasakan control plane beneran
- Alternatif: 1 managed K8s kecil (GKE Autopilot / DOKS) kalau ingin fokus ke database, bukan ke cluster admin

**Tooling wajib:** `kubectl`, `helm`, `k9s`, `stern`, `kubectx/kubens`, `psql`, `mongosh`, `clickhouse-client`, `rclone`, `pgcopydb`.

**Aturan:** semua manifest masuk Git sejak hari pertama. Tidak ada `kubectl edit` yang tidak tercatat.

---

## FASE 0 — Prasyarat (1 minggu)

Skip kalau sudah kuat, tapi jujur menilai diri sendiri.

**Linux & sistem**
- Proses, signal, `systemd`, `journalctl`
- Filesystem, mount, inode, `df` vs `du`
- Resource: cgroups v2, OOM killer, `/proc/meminfo`
- I/O: page cache, `fsync`, perbedaan `iops` vs `throughput` vs `latency`

**Networking**
- TCP handshake, port, NAT
- DNS: A record, CNAME, TTL, resolver
- TLS: handshake, cert chain, SNI, mTLS
- HTTP/1.1 vs HTTP/2, reverse proxy, load balancer L4 vs L7

**Container**
- Image layer, Dockerfile, multi-stage build
- Namespace & cgroup sebagai fondasi container
- Registry, tag vs digest (dan kenapa `:latest` itu bug)
- Volume, bind mount, `ENTRYPOINT` vs `CMD`

**Lain-lain**
- YAML: anchor, multiline block (`|` vs `>`), indentation traps
- Git: branch, rebase, tag
- SQL dasar: JOIN, GROUP BY, index, EXPLAIN

**Lab 0:** Bangun image Postgres kustom dengan satu extension tambahan, jalankan dengan `docker run`, isi data, restart container, buktikan data persist lewat named volume. Lalu hapus volume dan buktikan data hilang. Rasakan konsekuensinya.

---

## FASE 1 — Kubernetes Fundamental (3 minggu)

### Minggu 1: Arsitektur & Objek Inti

**Arsitektur**
- Control plane: `kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`
- Node: `kubelet`, `kube-proxy`, container runtime (containerd via CRI)
- Model deklaratif & reconciliation loop — ini konsep terpenting di seluruh K8s
- `etcd` sebagai satu-satunya sumber kebenaran (dan kenapa backup etcd itu wajib)

**Objek**
- Pod: multi-container, init container, sidecar, lifecycle hooks
- ReplicaSet → Deployment: rolling update, `maxSurge`/`maxUnavailable`, rollback
- Service: ClusterIP, NodePort, LoadBalancer, **Headless** (`clusterIP: None`) — headless krusial untuk database
- ConfigMap & Secret (dan kenapa Secret bawaan cuma base64, bukan enkripsi)
- Namespace, Label, Annotation, Selector
- Job & CronJob

**Latihan `kubectl`:** `get -o yaml`, `describe`, `logs -f --previous`, `exec`, `port-forward`, `explain`, `apply --dry-run=server`, `diff`.

### Minggu 2: Scheduling, Networking, Config

**Scheduling** — bagian ini menentukan apakah database-mu stabil atau tidak
- `requests` vs `limits`, QoS class (Guaranteed / Burstable / BestEffort)
- CPU throttling: **jangan set CPU limit pada pod database** — throttling di tengah query lebih buruk daripada noisy neighbor
- `nodeSelector`, `nodeAffinity`, `podAffinity`/`podAntiAffinity`
- Taints & Tolerations — dedikasikan node untuk database
- `topologySpreadConstraints` — sebar replika lintas zona/node
- PodDisruptionBudget — cegah drain node membunuh kuorum
- Priority & Preemption

**Networking**
- Model jaringan K8s: setiap Pod punya IP, flat network, no NAT antar pod
- CNI: Flannel (sederhana), Calico (NetworkPolicy kuat), Cilium (eBPF)
- CoreDNS: format FQDN `<svc>.<ns>.svc.cluster.local`, dan `<pod>.<svc>.<ns>.svc.cluster.local` untuk StatefulSet
- Ingress Controller (nginx / Traefik) vs **Gateway API** (arah masa depan)
- NetworkPolicy: default-deny, lalu allow eksplisit

**Config & Security dasar**
- RBAC: Role, ClusterRole, RoleBinding, ServiceAccount
- Pod Security Standards (baseline / restricted)
- `securityContext`: `runAsNonRoot`, `fsGroup`, `readOnlyRootFilesystem`

### Minggu 3: Packaging & GitOps

- Helm: chart structure, `values.yaml`, template function, `helm diff`, kapan Helm menyusahkan
- Kustomize: base + overlay, patch strategis
- GitOps: ArgoCD atau Flux — konsep desired state, drift detection, sync wave
- **Peringatan penting:** auto-sync + prune pada StatefulSet database bisa menghapus PVC. Selalu gunakan `Prune=false` atau finalizer proteksi untuk resource database.

**Lab 1 (kriteria lulus fase):**
Deploy aplikasi 3-tier (frontend, API, Redis) di `kind` dengan:
- Ingress + TLS via cert-manager (self-signed CA)
- NetworkPolicy default-deny, hanya jalur yang diperlukan yang dibuka
- Resource requests/limits masuk akal
- Semuanya dikelola ArgoCD dari repo Git
- Bunuh satu node, buktikan aplikasi tetap hidup

---

## FASE 2 — Stateful Workload & Storage (2 minggu)

Ini fondasi untuk tiga fase berikutnya. Jangan buru-buru.

### StatefulSet
- Perbedaan dengan Deployment: identitas jaringan stabil, ordinal index, ordered rollout
- `volumeClaimTemplates` — PVC per replika, tidak ikut terhapus saat pod dihapus
- `serviceName` + Headless Service → DNS per pod (`pg-0.pg-headless.db.svc.cluster.local`)
- `podManagementPolicy: Parallel` vs `OrderedReady`
- `updateStrategy`: `RollingUpdate` dengan `partition` untuk canary

### Storage
- PersistentVolume, PersistentVolumeClaim, StorageClass
- `volumeBindingMode: WaitForFirstConsumer` — hampir selalu yang kamu mau untuk local storage
- `reclaimPolicy: Retain` untuk database (jangan `Delete` — satu `kubectl delete pvc` yang salah = data hilang)
- `allowVolumeExpansion` dan cara expand PVC yang benar
- VolumeSnapshot & VolumeSnapshotClass (CSI snapshot)

### Memilih Storage Backend — keputusan paling berdampak
| Opsi | Latency | HA | Cocok untuk |
|---|---|---|---|
| `local-path-provisioner` (k3s default) | Terbaik | Tidak ada | Lab, atau DB dengan replikasi aplikasi |
| OpenEBS LocalPV / Mayastor | Sangat baik | Mayastor punya replikasi | Production dengan NVMe lokal |
| Longhorn | Sedang | Ya (replikasi blok) | General purpose, ops mudah |
| Rook-Ceph | Lebih lambat | Ya, kuat | Cluster besar, tim punya keahlian Ceph |
| Cloud CSI (EBS/PD) | Baik | Ya (per-zona) | Managed K8s |

**Prinsip yang perlu diinternalisasi:** untuk database, replikasi di level database (streaming replication Postgres, replica set MongoDB, ReplicatedMergeTree ClickHouse) hampir selalu lebih baik daripada replikasi di level blok. Storage terreplikasi menambah latency `fsync` pada setiap commit, dan kamu tetap butuh replika logis untuk failover cepat. Local NVMe + replikasi database = kombinasi paling umum di production serius.

### Operator Pattern
- CRD (CustomResourceDefinition) + Controller
- Reconciliation loop: observed state → desired state
- Kenapa database butuh operator: failover, backup terjadwal, upgrade terkoordinasi, bukan sekadar "jalankan proses"
- Baca kode satu operator sederhana untuk paham polanya

**Lab 2 (kriteria lulus fase):**
Buat StatefulSet 3-replika berisi aplikasi dummy yang menulis ke PVC. Lalu:
1. Hapus pod-1 → buktikan pod baru mount PVC yang sama
2. Cordon + drain node → amati perilaku (dan kenapa PDB penting)
3. Expand PVC dari 5Gi ke 10Gi tanpa downtime
4. Ambil VolumeSnapshot, hapus StatefulSet, restore dari snapshot

---

## FASE 3 — PostgreSQL di Kubernetes (3 minggu)

### Minggu 1: Postgres Sebagai Database (bukan sebagai pod)

Kamu tidak bisa mengoperasikan Postgres di K8s kalau tidak paham Postgres.

**Internal**
- Arsitektur proses: postmaster, backend per koneksi, background writer, WAL writer, checkpointer, autovacuum launcher
- MVCC: tuple versioning, `xmin`/`xmax`, snapshot isolation
- **Bloat & autovacuum** — penyebab #1 masalah Postgres di production. Pahami `autovacuum_vacuum_scale_factor`, dan kenapa tabel besar butuh setting per-tabel
- Transaction ID wraparound dan kenapa itu menakutkan
- WAL: `wal_level`, checkpoint, `full_page_writes`, archiving

**Tuning**
- `shared_buffers` (~25% RAM), `effective_cache_size` (~75%)
- `work_mem` — per operasi sort/hash, bukan per koneksi; gampang meledak
- `maintenance_work_mem`, `max_worker_processes`, `max_parallel_workers_per_gather`
- `max_connections` — jangan besar; pakai pooler
- `random_page_cost` untuk SSD (turunkan ke ~1.1)
- HugePages di Linux untuk `shared_buffers` besar

**Query & index**
- `EXPLAIN (ANALYZE, BUFFERS)` — baca beneran, jangan cuma lihat total time
- B-tree, GIN, GiST, BRIN, partial index, covering index (`INCLUDE`)
- `pg_stat_statements` untuk menemukan query paling mahal
- Partisi tabel (declarative partitioning)

**Replikasi**
- Streaming replication (physical): primary + standby, `wal_sender`, replication slot
- Synchronous vs asynchronous, `synchronous_commit` levels
- Logical replication: publication/subscription, batasannya (tidak replikasi DDL, sequence, TRUNCATE by default)
- Kapan pakai yang mana

### Minggu 2: CloudNativePG

**Kenapa CloudNativePG:** CNCF project, tidak butuh sidecar eksternal untuk failover, backup native ke object storage, deklaratif penuh, dokumentasi bagus. Alternatif yang layak dipertimbangkan: Zalando postgres-operator (matang, banyak dipakai), Percona PG Operator, StackGres (UI bagus), CrunchyData PGO.

**Topik**
- Install operator, `Cluster` CRD
- `instances`, `primaryUpdateStrategy`, `postgresql.parameters`
- Bootstrap methods: `initdb` (baru), `recovery` (dari backup), `pg_basebackup` (dari cluster lain — ini yang akan dipakai untuk migrasi)
- `storage` & `walStorage` — pisahkan WAL ke volume berbeda kalau bisa
- Replikasi sinkron: `synchronous.method`, `maxStandbyNamesFromCluster`
- Failover & switchover otomatis, `failoverDelay`
- Service yang dibuat operator: `-rw`, `-ro`, `-r` — pahami bedanya dan arahkan aplikasi dengan benar
- Connection pooling: `Pooler` CRD (PgBouncer), mode `transaction` vs `session`
- **Catatan versi:** arsitektur backup CNPG berpindah dari `backup.barmanObjectStore` inline ke plugin (`plugin-barman-cloud`). Cek dokumentasi versi operator yang kamu install, jangan ikut tutorial lama mentah-mentah.

**Backup & PITR**
- WAL archiving ke S3/MinIO
- `ScheduledBackup` CRD
- Point-in-time recovery: restore ke timestamp spesifik
- Retention policy

**Monitoring**
- Endpoint metrics bawaan CNPG + PodMonitor
- Metrik yang harus di-alert: replication lag, disk usage, connection saturation, oldest transaction age, WAL archive failure, backup age

### Minggu 3: Praktik

**Lab 3 (kriteria lulus fase):**
1. Deploy cluster CNPG 3 instance dengan replikasi sinkron, WAL di volume terpisah
2. Konfigurasi backup ke MinIO yang berjalan di cluster yang sama
3. Load ~5 GB data (pakai `pgbench -i -s 350`)
4. Jalankan `pgbench` sambil: `kubectl delete pod` pada primary. Ukur berapa detik sampai write kembali sukses. Catat angkanya.
5. Lakukan PITR: restore cluster baru ke kondisi 10 menit lalu, verifikasi datanya benar
6. Deploy PgBouncer via `Pooler`, bandingkan throughput 500 koneksi langsung vs lewat pooler
7. Upgrade minor version Postgres tanpa downtime
8. Sengaja bikin bloat (UPDATE massal), amati di `pg_stat_user_tables`, tuning autovacuum untuk mengatasinya

---

## FASE 4 — MongoDB di Kubernetes (1.5 minggu)

### Fundamental
- Model dokumen, BSON, batasan 16 MB per dokumen
- Schema design: embedding vs referencing, anti-pattern array tanpa batas
- Index: single, compound (aturan ESR: Equality, Sort, Range), multikey, TTL, partial, text
- Aggregation pipeline: `$match` → `$group` → `$project`, dan kenapa `$match` harus di depan
- `explain()` dan membaca `winningPlan`

### Replica Set
- Primary / Secondary / Arbiter (hindari arbiter kalau bisa)
- Oplog: capped collection, sizing, `oplog window` sebagai batas waktu recovery
- Election: `electionTimeoutMillis`, kenapa butuh jumlah ganjil untuk kuorum
- `writeConcern`: `w: 1` vs `w: "majority"` vs `j: true` — trade-off durability vs latency
- `readConcern` & `readPreference`
- Causal consistency, sessions, transaksi multi-dokumen (dan biayanya)

### Sharding
- Config server, `mongos`, shard
- Shard key: cardinality tinggi, distribusi merata, hindari monotonic (contoh: ObjectId murni)
- Hashed vs ranged sharding, chunk, balancer
- **Kapan sharding dibutuhkan:** kemungkinan besar belum. Pelajari konsepnya, tapi jangan implementasi kecuali working set sudah melebihi RAM satu node.

### Di Kubernetes
- **MongoDB Community Operator** — resmi, gratis, fitur terbatas (tidak ada backup terkelola)
- **Percona Server for MongoDB Operator (PSMDB)** — rekomendasi untuk self-hosted serius: backup via PBM, sharding, monitoring PMM
- Catatan lisensi: MongoDB berlisensi SSPL sejak v4.0. Untuk pemakaian internal ini tidak bermasalah, tapi kalau kamu menjual MongoDB-as-a-service, baca lisensinya. Percona Server for MongoDB adalah drop-in yang lebih permisif.
- `WiredTiger` cache: default ~50% (RAM − 1 GB). Di container, pastikan MongoDB membaca limit cgroup dengan benar, atau set `wiredTigerCacheSizeGB` eksplisit
- Storage: butuh IOPS tinggi, hindari network storage lambat

### Security
- SCRAM-SHA-256 untuk user, keyfile atau x.509 untuk auth internal antar member
- TLS: `net.tls.mode: requireTLS`
- Role-based access: buat role spesifik, jangan pakai `root` untuk aplikasi

### Backup
- `mongodump`/`mongorestore` — hanya untuk dataset kecil, tidak point-in-time
- **Percona Backup for MongoDB (PBM)** — logical & physical backup, PITR, konsisten lintas shard
- Filesystem snapshot: harus `fsyncLock` atau snapshot atomik

**Lab 4 (kriteria lulus fase):**
1. Deploy replica set 3-member dengan PSMDB Operator, TLS aktif
2. Isi 10 juta dokumen
3. Bunuh primary, ukur waktu election, verifikasi tidak ada write yang hilang dengan `w: "majority"`
4. Ulangi dengan `w: 1` — buktikan write bisa hilang. Ini pelajaran penting.
5. Konfigurasi PBM ke S3, jalankan backup, restore ke cluster baru
6. Buat query lambat, perbaiki dengan compound index sesuai aturan ESR, buktikan lewat `explain()`

---

## FASE 5 — ClickHouse di Kubernetes (2 minggu)

### Minggu 1: ClickHouse Sebagai OLAP Engine

**Paradigma**
- OLAP vs OLTP: ClickHouse bukan pengganti Postgres. Tidak ada transaksi, UPDATE/DELETE mahal, tapi agregasi miliaran baris dalam detik.
- Columnar storage: kompresi per kolom, hanya baca kolom yang diperlukan
- Vectorized execution

**MergeTree — inti dari segalanya**
- `ORDER BY` menentukan urutan fisik data dan sparse primary index. **Ini keputusan desain paling penting.** Urutkan dari kardinalitas rendah ke tinggi.
- `PRIMARY KEY` (opsional, prefix dari ORDER BY) vs `ORDER BY`
- Granule (default 8192 baris), mark, sparse index
- `PARTITION BY` — **anti-pattern paling umum:** partisi terlalu granular (per jam, atau per user). Aturan praktis: `toYYYYMM(date)`, target puluhan hingga ratusan partisi, bukan ribuan.
- Background merge, `system.merges`, `system.parts`
- `TTL` untuk data lifecycle: hapus otomatis, atau pindah ke storage dingin

**Varian MergeTree**
- `ReplacingMergeTree` — dedup eventual (bukan instan; butuh `FINAL` atau agregasi manual)
- `SummingMergeTree`, `AggregatingMergeTree`
- `CollapsingMergeTree` / `VersionedCollapsingMergeTree` — untuk CDC dan mutable data
- Materialized View + `AggregatingMergeTree` = pola pre-agregasi standar

**Ingestion — penyebab masalah #2**
- ClickHouse benci INSERT satu-baris. Batch minimal ribuan baris.
- `async_insert` untuk banyak client kecil
- Kafka table engine
- `INSERT ... SELECT` dari S3, URL, file

**Query**
- `SELECT` dengan `PREWHERE`
- Fungsi agregat kombinator: `-If`, `-Array`, `-State`, `-Merge`
- `EXPLAIN`, `system.query_log` untuk analisis
- Dictionaries untuk lookup cepat (pengganti JOIN)

### Minggu 2: Distribusi & Kubernetes

**Replikasi & Sharding**
- `ReplicatedMergeTree` + **ClickHouse Keeper** (pengganti ZooKeeper, jalankan ini bukan ZK untuk deployment baru)
- Zookeeper path & replica name, macros
- `Distributed` table engine sebagai lapisan query di atas shard
- Shard = skala, Replica = ketersediaan. Mulai dengan 1 shard × 2 replika. Sharding hanya kalau data melebihi kapasitas satu node.

**Altinity ClickHouse Operator**
- `ClickHouseInstallation` (CHI) CRD
- `ClickHouseKeeperInstallation` untuk Keeper
- `layout.shardsCount` / `replicasCount`
- `podTemplate`, `volumeClaimTemplate`, `serviceTemplate`
- Konfigurasi via `configuration.settings`, `profiles`, `users`
- Zone-aware placement dengan podAntiAffinity

**Tuning**
- `max_memory_usage`, `max_bytes_before_external_group_by` (spill ke disk)
- `max_threads`, background pool size
- Mark cache, uncompressed cache
- Tiered storage: hot (NVMe) → cold (S3) dengan storage policy

**Backup**
- `clickhouse-backup` — hardlink lokal + upload ke S3, incremental
- `BACKUP`/`RESTORE` statement native (versi baru)
- Freeze partition sebagai mekanisme dasar

**Lab 5 (kriteria lulus fase):**
1. Deploy Altinity Operator + ClickHouse Keeper 3-node + CHI dengan 2 shard × 2 replika
2. Ingest dataset publik (NYC Taxi atau GitHub Events, ~50–100 juta baris)
3. Rancang `ORDER BY` dan `PARTITION BY` untuk pola query tertentu, ukur waktu query
4. **Rancang ulang dengan `ORDER BY` yang salah, bandingkan.** Rasakan perbedaannya (bisa 10–100×).
5. Buat Materialized View untuk pre-agregasi harian, bandingkan latency vs query mentah
6. Bunuh satu replika saat query berjalan, verifikasi hasil tetap benar
7. Setup `clickhouse-backup` ke MinIO, restore ke cluster baru
8. Konfigurasi TTL: pindahkan data >30 hari ke S3

---

## FASE 6 — Operasional Day-2 (1.5 minggu)

Fase ini yang membedakan "bisa deploy" dan "bisa mengoperasikan".

### Observability
- Prometheus (via kube-prometheus-stack) + Grafana + Alertmanager
- Loki untuk log agregasi, `promtail`/`alloy`
- Exporter: CNPG native, `mongodb_exporter`/PMM, ClickHouse native metrics endpoint
- **Alert yang benar-benar berguna** (bukan CPU 80%):
  - Replication lag > threshold
  - Disk usage > 75% *dan* laju pertumbuhan
  - Backup terakhir > 25 jam yang lalu
  - WAL archive gagal
  - Connection pool saturation
  - Postgres: `oldest_transaction_age`, autovacuum stuck
  - ClickHouse: jumlah part per partisi (indikator merge tertinggal)
  - Mongo: oplog window menyusut

### Backup & Disaster Recovery
- Definisikan **RPO** (berapa data boleh hilang) dan **RTO** (berapa lama boleh down) secara eksplisit, angka, tertulis
- Aturan 3-2-1
- **Backup yang belum pernah di-restore bukan backup.** Jadwalkan restore drill bulanan, otomatis kalau bisa.
- Backup etcd cluster K8s terpisah dari backup database
- Simpan backup di provider/akun berbeda — ransomware dan kesalahan IAM itu nyata
- Dokumentasi runbook restore yang bisa diikuti orang lain jam 3 pagi

### Upgrade
- Urutan: upgrade K8s → verifikasi → upgrade operator → verifikasi → upgrade database
- Minor version DB: rolling, biasanya aman
- Major version Postgres: `pg_upgrade` atau logical replication (blue-green). Rencanakan berminggu-minggu.
- Selalu `PodDisruptionBudget` sebelum drain node

### Security
- RBAC least-privilege, ServiceAccount terpisah per workload
- NetworkPolicy default-deny per namespace, database hanya menerima dari namespace aplikasi
- Secret management: **External Secrets Operator** + Vault / AWS Secrets Manager / SOPS+age. Jangan commit Secret ke Git.
- cert-manager untuk TLS internal, rotasi otomatis
- Pod Security Standards `restricted` kalau memungkinkan
- Audit log apiserver
- Image scanning (Trivy), pinning digest

### Resource Management
- CPU limit pada database: **jangan**. Set requests tinggi + Guaranteed QoS via memory limit = request.
- Memory limit: harus ada (OOM lebih baik daripada node mati), tapi beri headroom besar
- Node dedikasi untuk database dengan taint
- HugePages untuk Postgres `shared_buffers` besar

**Lab 6 (kriteria lulus fase):**
Chaos day. Dengan ketiga database berjalan dan beban aktif:
1. Drain node yang berisi primary Postgres
2. Isi disk sampai 95% pada node ClickHouse
3. Putus jaringan antar node (simulasi split-brain) — amati perilaku kuorum
4. Hapus PVC secara "tidak sengaja" — buktikan `reclaimPolicy: Retain` menyelamatkanmu
5. Restore ketiga database dari backup ke cluster kosong. **Ukur waktunya.** Bandingkan dengan RTO yang kamu tulis.

---

## FASE 7 — Migrasi Supabase → Self-Hosted (2 minggu)

### 7.1 Pahami Apa Itu Supabase

Supabase = Postgres + lapisan layanan. Setiap komponen perlu keputusan tersendiri:

| Komponen | Fungsi | Schema DB terkait | Opsi saat self-host |
|---|---|---|---|
| PostgreSQL | Database | semua | CloudNativePG |
| **GoTrue** (supabase-auth) | Autentikasi, JWT | `auth` | Self-host GoTrue, atau ganti Keycloak/Zitadel/Authentik/Better Auth |
| **PostgREST** | Auto REST API dari schema | `public` | Self-host PostgREST, atau tulis API sendiri |
| **Realtime** | WAL → WebSocket | `realtime` | Self-host, atau ganti dengan LISTEN/NOTIFY, atau hapus |
| **Storage API** | File storage | `storage` | Self-host + MinIO/S3 |
| **Kong** | API Gateway | — | Ingress NGINX / Traefik / Kong |
| **Studio** | Dashboard | — | Self-host, atau pakai pgAdmin/DBeaver |
| **Edge Functions** | Deno runtime | — | Deno Deploy sendiri, atau port ke service biasa |
| **Supavisor** | Connection pooler | — | PgBouncer via CNPG `Pooler` |
| postgres-meta | API metadata | — | Hanya perlu kalau pakai Studio |

**Keputusan arsitektur — pilih satu:**

- **Opsi A: Full Supabase self-hosted di K8s.** Semua komponen dipindah. Aplikasi hampir tidak perlu diubah (cuma ganti URL). Chart komunitas: `supabase-community/supabase-kubernetes`. **Catatan jujur:** chart ini dipelihara komunitas, bukan resmi, dan sering tertinggal versi. Kamu akan jadi maintainer de-facto-nya.
- **Opsi B: Hanya Postgres self-hosted, ganti lapisan atas.** Postgres di CNPG, auth pakai solusi lain, API tulis sendiri. Lebih banyak kerja aplikasi di awal, jauh lebih sedikit beban ops jangka panjang.
- **Opsi C: Hybrid.** Postgres + PostgREST + GoTrue self-host (tiga komponen inti), buang Realtime/Storage/Edge Functions kalau tidak dipakai berat.

Untuk kebanyakan tim, **Opsi C** adalah titik seimbang. Tapi audit dulu (langkah berikutnya) sebelum memutuskan.

### 7.2 Audit & Inventarisasi (lakukan sebelum apa pun)

Jalankan dan catat hasilnya:

```sql
-- Versi Postgres
SELECT version();

-- Extension yang terpasang
SELECT extname, extversion FROM pg_extension ORDER BY extname;

-- Schema dan ukurannya
SELECT schemaname, pg_size_pretty(SUM(pg_total_relation_size(schemaname||'.'||tablename))::bigint)
FROM pg_tables GROUP BY schemaname ORDER BY 2 DESC;

-- Tabel terbesar
SELECT schemaname||'.'||relname AS tbl, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 25;

-- RLS policies
SELECT schemaname, tablename, policyname, roles, cmd
FROM pg_policies ORDER BY schemaname, tablename;

-- Roles
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin FROM pg_roles;

-- Function & trigger
SELECT n.nspname, p.proname, l.lanname FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
JOIN pg_language l ON l.oid=p.prolang
WHERE n.nspname NOT IN ('pg_catalog','information_schema');

SELECT event_object_schema, event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers;

-- pg_cron jobs (kalau ada)
SELECT * FROM cron.job;

-- Jumlah user auth
SELECT count(*) FROM auth.users;

-- Storage buckets & objek
SELECT id, name, public FROM storage.buckets;
SELECT bucket_id, count(*), pg_size_pretty(SUM((metadata->>'size')::bigint)) FROM storage.objects GROUP BY 1;
```

Checklist tambahan yang harus dicatat manual:
- [ ] Edge Functions apa saja, dan apa dependensinya
- [ ] Database Webhooks / `pg_net` calls ke mana
- [ ] Auth providers yang aktif (Google, GitHub, magic link, phone/SMS?) dan credential-nya
- [ ] Email template kustom, SMTP provider
- [ ] Realtime channels yang di-subscribe aplikasi
- [ ] Semua tempat di kode aplikasi yang hardcode URL Supabase atau anon key
- [ ] Cron jobs eksternal yang menghantam database

**Ekstensi Supabase yang tidak ada di image Postgres standar:** `pg_graphql`, `pgsodium`, `supabase_vault`, `pg_net`, `pgjwt`, `wrappers`, `pgmq`, `index_advisor`, `supautils`, `pg_tle`. Kalau aplikasimu memakai salah satunya, kamu perlu:
- Pakai image `supabase/postgres` sebagai base image di CloudNativePG, **atau**
- Build image kustom yang meng-compile extension yang diperlukan, **atau**
- Hilangkan ketergantungannya di aplikasi

Ini adalah blocker paling sering. Selesaikan lebih awal, bukan di hari cutover.

### 7.3 Siapkan Target

1. Deploy cluster CNPG dengan **versi mayor Postgres yang sama** dengan Supabase-mu
2. Gunakan image yang menyediakan semua extension yang dibutuhkan
3. Buat role yang sama: `anon`, `authenticated`, `service_role`, dan role aplikasimu. Grant-nya harus persis.
4. Install semua extension **sebelum** restore schema
5. Set `wal_level = logical` kalau akan pakai logical replication
6. Deploy MinIO (atau siapkan bucket S3) untuk Storage dan backup
7. Deploy PostgREST + GoTrue + komponen lain sesuai keputusan arsitektur

### 7.4 Strategi Migrasi Data — pilih sesuai ukuran & toleransi downtime

**Opsi 1: Cold migration (`pg_dump`/`pg_restore`)**
Cocok untuk: < 50 GB, downtime terjadwal boleh 1–4 jam.

```bash
# Schema dulu, terpisah
pg_dump "$SUPABASE_URL" \
  --schema-only --no-owner --no-privileges \
  --quote-all-identifiers \
  --schema=public --schema=auth --schema=storage \
  -f schema.sql

# Data
pg_dump "$SUPABASE_URL" \
  --data-only --no-owner --no-privileges \
  --quote-all-identifiers --disable-triggers \
  --schema=public --schema=auth --schema=storage \
  -Fc -f data.dump

# Restore ke target (extension harus sudah terpasang)
psql "$TARGET_URL" -f schema.sql
pg_restore -d "$TARGET_URL" --no-owner --no-privileges -j 4 data.dump
```

Catatan: kamu terkoneksi sebagai role `postgres` yang **bukan superuser** di Supabase hosted. Beberapa objek (event trigger, objek milik `supabase_admin`) akan gagal di-dump atau di-restore. Error semacam ini biasanya aman diabaikan — tapi baca setiap error, jangan asal skip.

**Opsi 2: Logical replication (near-zero downtime)**
Cocok untuk: 50 GB – beberapa TB, downtime hanya beberapa menit.

Alur: buat schema di target → buat `PUBLICATION` di Supabase → `SUBSCRIPTION` di target → initial copy berjalan → streaming menyusul → tunggu lag ≈ 0 → cutover.

**Rekomendasi kuat: pakai `pgcopydb`** daripada merangkai manual. Tool ini menangani schema, data paralel, index, sequence, dan follow mode dalam satu perintah:

```bash
pgcopydb clone \
  --source "$SUPABASE_URL" \
  --target "$TARGET_URL" \
  --table-jobs 8 --index-jobs 8 \
  --follow
```

Batasan logical replication yang harus kamu tangani manual:
- **Sequence tidak ikut tereplikasi.** Wajib resync saat cutover, atau aplikasi akan langsung kena duplicate key.
- DDL tidak tereplikasi — bekukan perubahan schema selama migrasi
- Tabel tanpa primary key butuh `REPLICA IDENTITY FULL`
- Large object tidak tereplikasi

Resync sequence saat cutover:
```sql
SELECT 'SELECT setval(''' || quote_ident(schemaname)||'.'||quote_ident(sequencename) ||
       ''', ' || last_value || ');'
FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog','information_schema');
-- jalankan output-nya di target
```

**Opsi 3: `pg_basebackup` via CNPG bootstrap**
Hanya berfungsi kalau Supabase mengizinkan koneksi replikasi fisik — umumnya **tidak** di tier hosted. Sebutkan di sini untuk kelengkapan; kemungkinan besar bukan jalurmu.

### 7.5 Migrasi Komponen Non-Database

**Auth / JWT — bagian paling sensitif**
- Tabel `auth.users` ikut terbawa oleh dump/replikasi. Password hash (bcrypt) tetap valid selama GoTrue target memakai algoritma sama.
- **JWT secret harus identik** kalau ingin token yang sudah beredar tetap valid. Kalau kamu rotate, semua user akan logout — kadang itu justru pilihan yang lebih bersih dan lebih aman.
- Supabase versi baru menggunakan asymmetric key (ES256/RS256) + JWKS endpoint. Kalau projectmu sudah pakai ini, konfigurasi GoTrue target dengan key pair yang sama, atau rencanakan re-login massal.
- Konfigurasi ulang setiap OAuth provider dengan redirect URI baru — ini sering terlupa sampai hari cutover.
- Uji: login password, magic link, OAuth, refresh token, password reset. Satu per satu.

**Storage**
1. Salin objek dari Supabase Storage (S3-compatible) ke bucket sendiri:
   ```bash
   rclone sync supabase-s3:bucket-name minio:bucket-name --progress --transfers 16
   # verifikasi
   rclone check supabase-s3:bucket-name minio:bucket-name
   ```
2. Tabel `storage.objects` & `storage.buckets` ikut migrasi database
3. Konfigurasi `storage-api` menunjuk ke MinIO/S3 baru
4. Verifikasi: upload baru, download lama, signed URL, RLS pada storage

**Realtime**
- Publication `supabase_realtime` harus dibuat ulang di target
- Schema `realtime` ikut migrasi
- Uji subscribe/broadcast dari aplikasi

**Edge Functions**
- Tidak ada di database sama sekali. Deploy ulang sebagai Deno service di K8s, atau port ke bahasa lain.
- Perhatikan secrets/env var yang dipakai

**Connection string**
- Supabase: port `5432` (direct/session) vs `6543` (Supavisor, transaction mode)
- Target: service `-rw` CNPG untuk write, `-ro` untuk read, atau lewat `Pooler`
- **Penting:** kalau aplikasimu memakai prepared statement dan kamu pindah ke PgBouncer transaction mode, kamu akan kena error. Set `prepareThreshold=0` / `statement_cache_size=0` di driver, atau pakai session mode.

### 7.6 Rencana Cutover

Tulis ini sebagai dokumen terpisah dengan penanggung jawab dan waktu per langkah.

**T-7 hari**
- [ ] Dry run migrasi penuh ke staging, ukur durasinya
- [ ] Semua tes fungsional lulus di staging
- [ ] Rollback plan tertulis dan sudah diuji
- [ ] Turunkan TTL DNS ke 60 detik

**T-1 hari**
- [ ] Bekukan perubahan schema
- [ ] Logical replication berjalan, lag stabil ≈ 0
- [ ] Backup final Supabase diambil dan disimpan
- [ ] Komunikasikan jendela maintenance

**T-0 (cutover)**
1. Aktifkan maintenance mode / hentikan write di aplikasi
2. Tunggu replication lag = 0 (verifikasi di `pg_stat_replication`)
3. Hentikan replikasi, promote target
4. **Resync semua sequence**
5. Verifikasi: row count per tabel, checksum sampel, `SELECT count(*) FROM auth.users`
6. Update connection string / DNS / env var aplikasi
7. Jalankan smoke test: login, query utama, upload file, realtime
8. Lepas maintenance mode
9. Pantau intensif 2 jam

**T+1 hari**
- [ ] Ambil backup penuh pertama dari sistem baru, **dan uji restore-nya**
- [ ] Bandingkan `pg_stat_statements` dengan baseline Supabase — cari regresi performa
- [ ] Semua alert aktif dan terverifikasi
- [ ] Jangan hapus project Supabase. Tunggu minimal 30 hari.

**Kriteria rollback (tentukan di awal, bukan saat panik):**
Contoh: error rate > 2% selama 10 menit, atau p95 latency > 3× baseline, atau ada kehilangan data terdeteksi → kembalikan connection string ke Supabase.

**Lab 7 (kriteria lulus fase):**
Buat project Supabase gratis, isi dengan data realistis (tabel + RLS + auth users + storage objects), lalu migrasikan seluruhnya ke cluster K8s-mu dengan downtime terukur < 5 menit. Dokumentasikan setiap langkah dan setiap hal yang gagal.

---

## FASE 8 — Capstone (1 minggu)

Bangun dan dokumentasikan satu sistem utuh:

**Arsitektur target**
- Cluster K8s (3 node, k3s di VPS)
- PostgreSQL (CloudNativePG, 3 instance, sync replication) — OLTP
- MongoDB (PSMDB, replica set 3-member) — dokumen/log semi-terstruktur
- ClickHouse (Altinity, 1 shard × 2 replika + Keeper) — analytics
- CDC Postgres → ClickHouse (Debezium/Kafka atau PeerDB) untuk analitik near-real-time
- MinIO untuk backup semua database
- Prometheus + Grafana + Loki + Alertmanager
- ArgoCD mengelola semuanya dari satu repo
- cert-manager + External Secrets Operator
- Aplikasi demo yang dimigrasikan dari Supabase

**Deliverable**
1. Repo Git yang bisa mereproduksi seluruh stack dari nol
2. Runbook: restore setiap database, failover manual, prosedur upgrade
3. Dokumen SLO dengan RPO/RTO per database, dan bukti pengukuran
4. Dashboard Grafana + alert rules
5. Laporan chaos test: apa yang kamu rusak, apa yang terjadi, apa yang kamu perbaiki
6. Analisis biaya: self-hosted vs Supabase vs managed, termasuk estimasi jam kerja ops

---

## Referensi

**Kubernetes**
- Dokumentasi resmi kubernetes.io (mulai dari Concepts, bukan Tutorials)
- *Kubernetes Patterns* — Bilgin Ibryam & Roland Huß
- *Programming Kubernetes* — Hausenblas & Schimanski (untuk paham operator)
- CKA/CKAD curriculum sebagai checklist cakupan

**PostgreSQL**
- Dokumentasi resmi postgresql.org (bab Server Administration & Performance Tips)
- *PostgreSQL 14 Internals* — Egor Rogov (gratis, sangat bagus untuk MVCC/WAL)
- Dokumentasi CloudNativePG
- Blog: pganalyze, Cybertec, Percona

**MongoDB**
- MongoDB University (gratis): M001, M103, M201
- Dokumentasi Percona Operator for MongoDB & PBM

**ClickHouse**
- Dokumentasi clickhouse.com — khususnya bagian "Best Practices" dan "Primary Indexes"
- Altinity Knowledge Base & blog (sumber terbaik untuk operasional)
- ClickHouse Academy

**Supabase**
- Dokumentasi self-hosting resmi Supabase
- Repo: `supabase/supabase` (docker-compose sebagai referensi konfigurasi), `supabase-community/supabase-kubernetes`
- Dokumentasi PostgREST & GoTrue terpisah

**Migrasi**
- `pgcopydb` documentation
- Panduan migrasi resmi Supabase (baik untuk masuk maupun keluar)

---

## Checklist Penilaian Diri

Kamu selesai kalau bisa menjawab semua ini tanpa mencari:

**Kubernetes**
- [ ] Kenapa StatefulSet, bukan Deployment, untuk database?
- [ ] Apa yang terjadi pada PVC saat StatefulSet dihapus? Bagaimana mencegah kehilangan data?
- [ ] Kenapa CPU limit berbahaya untuk pod database?
- [ ] Bagaimana PDB melindungi kuorum saat node drain?

**PostgreSQL**
- [ ] Apa itu bloat dan kenapa autovacuum bisa tertinggal?
- [ ] Beda `synchronous_commit = on` vs `remote_apply`?
- [ ] Bagaimana melakukan PITR ke 14:32 kemarin?
- [ ] Kenapa `work_mem` besar bisa membunuh server?

**MongoDB**
- [ ] Kenapa `w: 1` bisa kehilangan write saat failover?
- [ ] Apa aturan ESR untuk compound index?
- [ ] Apa konsekuensi oplog window yang terlalu pendek?

**ClickHouse**
- [ ] Kenapa `ORDER BY` lebih penting daripada index tradisional?
- [ ] Kenapa partisi per jam adalah ide buruk?
- [ ] Kenapa INSERT satu-baris merusak performa?
- [ ] Kapan `ReplacingMergeTree` belum melakukan dedup?

**Operasional**
- [ ] Kapan terakhir kamu me-restore backup? (Kalau jawabannya "belum pernah", kamu tidak punya backup.)
- [ ] Berapa RPO dan RTO tiap database, dan apa buktinya?
- [ ] Apa yang terjadi kalau node yang menjalankan primary mati sekarang juga?

**Migrasi**
- [ ] Extension Supabase apa yang dipakai aplikasimu, dan bagaimana menyediakannya sendiri?
- [ ] Kenapa sequence harus di-resync manual pada logical replication?
- [ ] Apa yang terjadi pada token JWT user kalau JWT secret berubah?

---

## Catatan Penutup

Silabus ini mengasumsikan kamu ingin menguasai domainnya, bukan sekadar menyelesaikan satu migrasi. Kalau tujuanmu murni "keluar dari Supabase secepatnya", jalur tercepat adalah: Fase 3 minggu 1 (Postgres fundamental) + Fase 7 (migrasi), dengan Postgres di VM biasa memakai pgBackRest — sekitar 3 minggu, bukan 16. Kubernetes bisa menyusul nanti setelah sistemnya stabil.

Urutan fase juga bisa disesuaikan: kalau ClickHouse tidak mendesak, geser Fase 5 ke belakang Fase 7. Yang tidak boleh dilewati adalah Fase 2 (storage) dan Fase 6 (day-2 ops) — dua fase itu yang paling sering diabaikan dan paling sering jadi penyebab insiden.

