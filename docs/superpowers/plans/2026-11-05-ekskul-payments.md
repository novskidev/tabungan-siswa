# Iuran Ekstrakurikuler Mingguan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Membangun fitur pencatatan iuran ekstrakurikuler mingguan (Rp3.000/Kamis) berbasis checklist untuk guru pembina dan kartu pantauan status/riwayat ber-PIN untuk orang tua murid.

**Architecture:** Data pembayaran iuran disimpan pada tabel terpisah `ekskul_payments` di PostgreSQL (Supabase) dengan relasi ke siswa dan tanggal Kamis. Guru pembina ekskul (ditugaskan oleh master via flag `profiles.is_ekskul_teacher`) mengelola pembayaran di `/guru/ekskul`, sedangkan orang tua mengakses status dan riwayat melalui RPC `get_student_ekskul_history` di halaman publik `/siswa/[public_code]` ber-PIN.

**Tech Stack:** Astro 7 (SSR), TypeScript, Tailwind CSS v4, Supabase (PostgreSQL, RLS, PL/pgSQL RPCs), Bun test.

**Spec:** `docs/superpowers/specs/2026-11-05-ekskul-payments-design.md`

## Global Constraints
- Pembayaran tunai fisik langsung ke guru: tidak memotong dan tidak mencemari ledger saldo tabungan siswa.
- Nominal flat: Rp3.000 untuk Lunas (`paid`) dan Tunggakan (`unpaid`), Rp0 untuk Tidak Masuk (`absent`).
- Penentuan tanggal Kamis mengacu pada zona waktu `Asia/Jakarta` (WIB).
- Akses orang tua aman: orang tua tidak memiliki akses tabel langsung, hanya melalui `SECURITY DEFINER` RPC dengan validasi PIN bcrypt (`crypt(p_pin, pin_hash)`).
- Strict typecheck: `bun run typecheck` dan `bun run build` harus lulus tanpa error.

## Review Focus
1. Transaksi ekskul tidak boleh mengubah nilai saldo yang dihitung oleh `getStudentBalance()` di `src/lib/transactions.ts`.
2. Tanggal di luar hari Kamis: sistem helper otomatis mengonversi/membulatkan tanggal yang dipilih ke hari Kamis terdekat di WIB.
3. Duplikasi catatan pada hari Kamis yang sama dicegah oleh constraint `UNIQUE(student_id, payment_date)`.
4. Guru non-pembina yang mencoba mengakses `/guru/ekskul` diarahkan kembali (*redirect*) ke `/guru`.
5. Siswa non-aktif (`is_active = false`) tidak dimunculkan di form checklist guru aktif, namun riwayat lamanya tetap dapat dilihat orang tua dengan PIN.

---

### Task 1: Supabase Database Migration & RPCs

**Files:**
- Create: `supabase/migrations/20261105000000_ekskul_payments.sql`

**Interfaces:**
- Produces:
  - Column: `profiles.is_ekskul_teacher` (`boolean`, default `false`)
  - Table: `public.ekskul_payments` (`id`, `student_id`, `payment_date`, `status`, `amount`, `note`, `recorded_by`, `created_at`, `updated_at`)
  - RPC: `public.toggle_ekskul_teacher(p_teacher_id uuid, p_is_ekskul boolean)`
  - RPC: `public.save_ekskul_payment(p_student_id uuid, p_payment_date date, p_status text, p_note text)`
  - RPC: `public.bulk_save_ekskul_payments(p_student_ids uuid[], p_payment_date date, p_status text)`
  - RPC: `public.get_student_ekskul_history(p_code text, p_pin text)`

- [ ] **Step 1: Write migration SQL in `supabase/migrations/20261105000000_ekskul_payments.sql`**
  - Tambah kolom `is_ekskul_teacher` ke `public.profiles`.
  - Buat tabel `public.ekskul_payments` dengan constraint check status (`paid`, `unpaid`, `absent`) dan unique `(student_id, payment_date)`.
  - Buat RLS policy untuk authenticated users (master atau pembina ekskul).
  - Buat RPC `toggle_ekskul_teacher` (hanya role master).
  - Buat RPC `save_ekskul_payment` & `bulk_save_ekskul_payments` dengan UPSERT (`ON CONFLICT (student_id, payment_date) DO UPDATE`).
  - Buat RPC `get_student_ekskul_history(p_code text, p_pin text)` yang memverifikasi PIN dan mengembalikan JSON ringkasan + riwayat mingguan.

- [ ] **Step 2: Apply migration to Supabase using MCP execute_sql**
  - Jalankan script SQL migration ke database remote Supabase proyek `rivwwbtllsloyrjsyiir`.
  - Verifikasi tabel dan RPC terbentuk dengan query `information_schema.tables` dan `pg_proc`.

- [ ] **Step 3: Commit migration**
  ```bash
  git add supabase/migrations/20261105000000_ekskul_payments.sql
  git commit -m "db: add ekskul_payments table and RPCs"
  ```

---

### Task 2: Core Helpers & TypeScript Definitions

**Files:**
- Create: `src/lib/ekskul.ts`
- Create: `tests/ekskul.test.ts`
- Modify: `src/types/database.ts`
- Modify: `src/lib/supabase.ts:6-12,85-95`

**Interfaces:**
- Consumes: Supabase database schema
- Produces:
  - Types in `src/types/database.ts`: `EkskulStatus = 'paid' | 'unpaid' | 'absent'`, `EkskulPaymentRow`, `EkskulSummary`
  - Updated `Profile` in `src/lib/supabase.ts`: includes `is_ekskul_teacher: boolean`
  - Helper functions in `src/lib/ekskul.ts`:
    - `getThursdayOfWeek(date: Date, tz?: string): string` (mengembalikan format YYYY-MM-DD hari Kamis minggu tersebut)
    - `getAdjacentThursday(thursdayStr: string, weeksOffset: number): string`
    - `formatKamisLabel(thursdayStr: string): string` (mis. "Kamis, 6 November 2026")
    - `getEkskulStatusBadge(status: EkskulStatus | null): { label: string; class: string }`

- [ ] **Step 1: Write failing unit test in `tests/ekskul.test.ts`**
  - Test `getThursdayOfWeek` untuk berbagai hari (Senin, Kamis, Sabtu, Minggu) agar selalu mengembalikan tanggal hari Kamis di minggu tersebut dalam timezone `Asia/Jakarta`.
  - Test `getAdjacentThursday` untuk pergeseran +1 minggu dan -1 minggu.

- [ ] **Step 2: Run test to verify it fails**
  Run: `bun test tests/ekskul.test.ts`
  Expected: FAIL with "module not found"

- [ ] **Step 3: Implement helper functions in `src/lib/ekskul.ts`, update `src/types/database.ts` and `src/lib/supabase.ts`**
  - Tulis logika `getThursdayOfWeek`, `getAdjacentThursday`, `formatKamisLabel`.
  - Perbarui interface `Profile` di `src/lib/supabase.ts` agar menyertakan `is_ekskul_teacher` pada query `getCurrentProfile`.

- [ ] **Step 4: Run test to verify it passes**
  Run: `bun test tests/ekskul.test.ts`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add src/lib/ekskul.ts src/types/database.ts src/lib/supabase.ts tests/ekskul.test.ts
  git commit -m "feat(ekskul): add date helpers, types, and profile field"
  ```

---

### Task 3: Master Management & Navigation

**Files:**
- Modify: `src/pages/master/index.astro`
- Modify: `src/components/Nav.astro`
- Modify: `src/middleware.ts`

**Interfaces:**
- Consumes: `toggle_ekskul_teacher` RPC, `Profile.is_ekskul_teacher`
- Produces: UI toggle di `/master` untuk status pembina ekskul guru, route guard middleware untuk `/guru/ekskul`, link navigasi baru `🎯 Ekskul`.

- [ ] **Step 1: Update `src/pages/master/index.astro`**
  - Tambahkan penanganan `action === 'toggle_ekskul'` yang memanggil RPC `toggle_ekskul_teacher`.
  - Di daftar guru, tampilkan status apakah guru adalah "Pembina Ekskul" dengan tombol toggle untuk mengaktifkan/menonaktifkan.

- [ ] **Step 2: Update `src/components/Nav.astro`**
  - Tambahkan menu item `{ key: 'ekskul', label: 'Ekskul', icon: '🎯', href: '/guru/ekskul' }` jika `role === 'master'` atau `profile.is_ekskul_teacher === true`.

- [ ] **Step 3: Update `src/middleware.ts`**
  - Tambahkan guard untuk path `/guru/ekskul`: jika guru yang login bukan master dan bukan pembina ekskul (`!profile.is_ekskul_teacher`), redirect ke `/guru`.

- [ ] **Step 4: Run typecheck to verify no regression**
  Run: `bun run typecheck`
  Expected: PASS with 0 errors

- [ ] **Step 5: Commit**
  ```bash
  git add src/pages/master/index.astro src/components/Nav.astro src/middleware.ts
  git commit -m "feat(ekskul): add master management, nav link, and route guard"
  ```

---

### Task 4: Teacher Ekskul Attendance & Payment Checklist Page

**Files:**
- Create: `src/pages/guru/ekskul/index.astro`

**Interfaces:**
- Consumes: `getThursdayOfWeek`, `getAdjacentThursday`, `formatKamisLabel` dari `src/lib/ekskul.ts`, RPC `save_ekskul_payment` & `bulk_save_ekskul_payments`.
- Produces: Halaman checklist operasional `/guru/ekskul`.

- [ ] **Step 1: Implement `src/pages/guru/ekskul/index.astro`**
  - Require role teacher/master dengan cek `is_ekskul_teacher` atau master.
  - Baca query param `?date=YYYY-MM-DD` (default ke Kamis minggu berjalan via `getThursdayOfWeek(new Date())`).
  - Baca daftar siswa aktif (`is_active = true`) beserta kelasnya, diurutkan per kelas & nama.
  - Ambil data `ekskul_payments` untuk tanggal Kamis terpilih.
  - Tampilkan tombol navigasi tanggal (`< Kamis Sebelumnya`, tanggal saat ini, `Kamis Berikutnya >`).
  - Sediakan filter kelas (Semua Kelas, Kelas 1-6).
  - Tampilkan tombol aksi cepat: *"Tandai Semua Masuk & Lunas"* (bulk save).
  - Tampilkan kartu/baris setiap siswa dengan opsi status cepat: **Lunas (Rp3.000)**, **Tunggakan (Rp3.000)**, **Tidak Masuk (Rp0)**.
  - Tangani POST form: simpan status per siswa atau simpan massal.

- [ ] **Step 2: Run typecheck**
  Run: `bun run typecheck`
  Expected: PASS

- [ ] **Step 3: Commit**
  ```bash
  git add src/pages/guru/ekskul/index.astro
  git commit -m "feat(ekskul): add teacher checklist and payment tracking page"
  ```

---

### Task 5: Parent PIN-Gated Public View

**Files:**
- Modify: `src/pages/siswa/[public_code].astro`

**Interfaces:**
- Consumes: RPC `get_student_ekskul_history(p_code, p_pin)`
- Produces: Komponen kartu status ekskul di halaman publik siswa setelah verifikasi PIN berhasil.

- [ ] **Step 1: Modify `src/pages/siswa/[public_code].astro`**
  - Ketika PIN valid (pada alur verifikasi utama maupun ganti PIN), panggil RPC `get_student_ekskul_history`.
  - Tampilkan kartu *"Iuran Ekstrakurikuler (Kamis)"* di bawah saldo tabungan:
    - Status Kamis minggu ini: Badge warna (Hijau: Lunas, Kuning: Tunggakan, Abu-abu: Tidak Masuk, Biru muda: Belum Ada Catatan).
    - Total tunggakan siswa (mis. "Rp0" atau "Rp6.000 (2 pertemuan)").
    - Daftar riwayat pertemuan Kamis sebelumnya (maks. 8-12 pertemuan terakhir) lengkap dengan tanggal, status, dan nominal.

- [ ] **Step 2: Run typecheck**
  Run: `bun run typecheck`
  Expected: PASS

- [ ] **Step 3: Commit**
  ```bash
  git add src/pages/siswa/[public_code].astro
  git commit -m "feat(ekskul): display ekskul payment status and history on parent public page"
  ```

---

### Task 6: Full Verification, Build, & Integration Test

**Files:**
- Test: `tests/ekskul.test.ts`
- Verification commands: `bun test`, `bun run typecheck`, `bun run build`

- [ ] **Step 1: Run unit tests**
  Run: `bun test`
  Expected: All tests PASS

- [ ] **Step 2: Run Astro typecheck**
  Run: `bun run typecheck`
  Expected: 0 errors

- [ ] **Step 3: Run production build & bundling**
  Run: `bun run build`
  Expected: Astro build + esbuild postbuild bundle `dist/client/_worker.js` SUCCEED

- [ ] **Step 4: Verify live RPC and schema on Supabase**
  - Jalankan query verifikasi integrity check di Supabase remote untuk memastikan tidak ada error pada function `get_student_ekskul_history`.

- [ ] **Step 5: Final commit**
  ```bash
  git add -A
  git commit -m "chore: complete ekskul payment implementation and pass all checks"
  ```
