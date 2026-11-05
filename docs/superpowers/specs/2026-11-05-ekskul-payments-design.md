# Design Doc: Iuran Ekstrakurikuler Mingguan SDN Klagen 1

**Date:** 2026-11-05  
**Author:** novskidev & agent  
**Status:** Approved  

---

## 1. Intent & The Why

SDN Klagen 1 memiliki kegiatan ekstrakurikuler mingguan setiap hari Kamis dengan iuran Rp3.000 per siswa secara tunai. Saat ini, belum ada buku catatan digital untuk mencatat riwayat pembayaran, status tunggakan, maupun kehadiran bayar siswa. Akibatnya, orang tua murid tidak mengetahui apakah anaknya sudah membayar iuran minggu ini atau memiliki tunggakan, dan guru pembina kesulitan merekap iuran.

Fitur ini menyediakan buku catatan iuran ekstrakurikuler digital yang ringan:
- Guru pembina ekstrakurikuler dapat mencatat status pembayaran (Lunas, Tunggakan, Tidak Masuk/Bebas Iuran) dengan cepat via checklist per hari Kamis.
- Orang tua dapat memantau status iuran anak minggu berjalan serta riwayat pembayaran minggu-minggu sebelumnya langsung dari halaman tabungan ber-PIN tanpa login tambahan.

---

## 2. Goals, Non-Goals & Anti-Goals

### Goals
- **Pencatatan Cepat & Terisolasi**: Guru pembina dapat menandai status iuran siswa per hari Kamis dengan satu klik atau opsi massal ("Tandai Semua Masuk & Lunas").
- **Transparansi Orang Tua**: Orang tua dapat melihat status Kamis minggu ini dan riwayat 4-8 minggu sebelumnya di `/siswa/[public_code]` setelah memasukkan PIN.
- **Tunggal & Akurat**: Nominal iuran flat Rp3.000. Siswa yang tidak masuk sekolah diberi status "Tidak Masuk" (bebas iuran Rp0), sedangkan yang masuk tapi tidak bayar dicatat "Tunggakan" (Rp3.000).
- **Multi-Kelas**: Pembina ekskul dapat mengelola pembayaran semua siswa aktif lintas kelas (Kelas 1–6).

### Non-Goals
- Tidak ada pemotongan otomatis dari saldo tabungan siswa. Pembayaran murni tunai fisik langsung ke guru.
- Tidak ada pembayaran online / payment gateway / QRIS.
- Tidak ada notifikasi pesan WhatsApp / SMS ke orang tua.
- Tidak ada nominal iuran kustom atau parsial (misal bayar Rp1.500).

### Anti-Goals
- **Mencemari Ledger Tabungan**: Jangan memasukkan transaksi ekskul ke tabel `transactions` tabungan. Ledger tabungan harus tetap bersih dan berdiri sendiri.
- **Over-complicated Attendance**: Jangan membuat sistem absensi sekolah umum. Catatan "Tidak Masuk" di sini murni untuk justifikasi pembebasan iuran ekskul di hari Kamis tersebut.

---

## 3. Constraints
- **Database**: Supabase PostgreSQL dengan RLS ketat. Akses orang tua hanya melalui PostgreSQL RPC berstatus `SECURITY DEFINER` dengan verifikasi PIN (bcrypt).
- **Timezone**: Seluruh komputasi tanggal Kamis menggunakan zona waktu `Asia/Jakarta` (WIB) agar serasi dengan kalender sekolah lokal.
- **Roles**:
  - `master`: Mengelola guru pembina ekskul di `/master` dan memiliki akses penuh ke `/guru/ekskul`.
  - `teacher` dengan `is_ekskul_teacher = true`: Memiliki akses khusus ke halaman `/guru/ekskul`.
  - `teacher` biasa (non-pembina): Akses dibatasi dari `/guru/ekskul`.

---

## 4. Approaches Considered

1. **Pendekatan A: Integrasi ke Tabel `transactions` sebagai Jenis Transaksi Baru**
   - Menambahkan tipe transaksi baru `ekskul_fee` di tabel `transactions`.
   - *Trade-off*: Merusak prinsip single source of truth saldo tabungan (`balance = deposit - withdrawal`), karena user secara eksplisit meminta pembayaran tunai langsung tanpa memotong tabungan.
   - *Keputusan*: Ditolak.

2. **Pendekatan B: Tabel Terpisah `ekskul_payments` + Public RPC Gated by PIN (Dipilih)**
   - Membuat tabel terpisah `ekskul_payments` dengan constraint `UNIQUE(student_id, payment_date)`.
   - Menambahkan flag `is_ekskul_teacher` di `profiles`.
   - Menambahkan RPC `get_student_ekskul_history(p_code text, p_pin text)` untuk orang tua.
   - *Trade-off*: Perlu tabel baru dan RPC baru, tetapi menjaga integritas data tabungan tetap 100% aman dan bersih.
   - *Keputusan*: Disetujui.

---

## 5. Detailed Specifications

### Database Schema

1. **Migration: `20261105000000_ekskul_payments.sql`**
   - Kolom baru di `public.profiles`:
     - `is_ekskul_teacher boolean not null default false`
   - Tabel baru `public.ekskul_payments`:
     ```sql
     create table public.ekskul_payments (
       id uuid primary key default gen_random_uuid(),
       student_id uuid not null references public.students(id) on delete restrict,
       payment_date date not null,
       status text not null check (status in ('paid', 'unpaid', 'absent')),
       amount numeric not null default 3000 check (amount >= 0),
       note text,
       recorded_by uuid not null references public.profiles(id) on delete restrict,
       created_at timestamptz not null default now(),
       updated_at timestamptz not null default now(),
       constraint ekskul_payments_student_date_uniq unique (student_id, payment_date)
     );
     ```
   - Indexes:
     - `(payment_date)`
     - `(student_id, payment_date desc)`
   - RLS Policies on `ekskul_payments`:
     - Enable RLS.
     - `SELECT`, `INSERT`, `UPDATE` hanya untuk user yang terautentikasi dan memiliki profil `master` atau `is_ekskul_teacher = true`.

2. **PostgreSQL RPCs**:
   - `save_ekskul_payment(p_student_id uuid, p_payment_date date, p_status text, p_note text default null)`:
     - `SECURITY DEFINER` (atau `INVOKER` dengan RLS yang sesuai).
     - Validasi pemanggil adalah `master` atau pembina ekskul.
     - UPSERT row di `ekskul_payments` (`ON CONFLICT (student_id, payment_date) DO UPDATE SET status = EXCLUDED.status, amount = EXCLUDED.amount, recorded_by = auth.uid(), updated_at = now()`).
   - `toggle_ekskul_teacher(p_teacher_id uuid, p_is_ekskul boolean)`:
     - Hanya master yang boleh memanggil.
     - Mengubah nilai `is_ekskul_teacher` pada `profiles`.
   - `get_student_ekskul_history(p_code text, p_pin text)`:
     - `SECURITY DEFINER`.
     - Memverifikasi PIN dengan `crypt(p_pin, pin_hash)`.
     - Mengembalikan ringkasan ekskul:
       - Status Kamis minggu ini (`this_thursday_status`).
       - Total tunggakan (`unpaid_count`, `unpaid_amount`).
       - Array riwayat pembayaran minggu-minggu sebelumnya (maksimal 12 minggu).

### UI & Navigation

1. **Navigasi Guru (`src/components/Nav.astro`)**:
   - Menambahkan menu **Ekskul** (`🎯 Ekskul` &rarr; `/guru/ekskul`) bagi guru yang memiliki `is_ekskul_teacher = true` atau role `master`.
2. **Kelola Master (`src/pages/master/index.astro`)**:
   - Di daftar guru, tampilkan badge atau toggle untuk menugaskan/mencabut status "Pembina Ekskul".
3. **Halaman Guru Ekskul (`src/pages/guru/ekskul/index.astro`)**:
   - Proteksi middleware & frontmatter: hanya guru ekskul atau master.
   - Pemilih tanggal Kamis: tombol `[< Kamis Lalu]`, dropdown / input tanggal Kamis, tombol `[Kamis Depan >]`.
   - Filter kelas: Semua Kelas, Kelas 1, 2, 3, 4, 5, 6.
   - Aksi Massal: Tombol "Tandai Semua Masuk & Lunas".
   - Tabel/Kartu Siswa: Tombol radio atau switch cepat untuk `Lunas (Rp3.000)`, `Tunggakan (Rp3.000)`, `Tidak Masuk (Rp0)`.
4. **Halaman Publik Siswa (`src/pages/siswa/[public_code].astro`)**:
   - Menampilkan card status "Iuran Ekstrakurikuler" setelah verifikasi PIN berhasil:
     - Status Kamis Minggu Ini (Badge hijau "LUNAS", kuning "TUNGGAKAN", abu-abu "TIDAK MASUK", atau netral "BELUM DICATAT").
     - Total tunggakan (misal "Rp6.000 (2 pertemuan)").
     - Riwayat pertemuan sebelumnya dalam bentuk list rapi.
