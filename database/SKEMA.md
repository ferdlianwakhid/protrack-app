# Kamus Data — Deteksi Kehamilan Dini (Fuzzy Tsukamoto)

Dokumen ini menjelaskan, untuk setiap kolom di `database/schema.sql`:
**wajib atau tidak**, **nilainya dari mana**, dan **berelasi ke tabel mana**.

---

## Cara membaca kolom "Asal nilai"

| Label | Artinya |
|---|---|
| `OTOMATIS` | Diisi database sendiri (`AUTO_INCREMENT` atau `DEFAULT`). Program tidak perlu mengirim apa-apa. |
| `AWAL` | Data awal, diisi sekali saat instalasi lewat `INSERT` di `schema.sql`. Isinya pengetahuan bidan. |
| `PENGGUNA` | Diisi dari form yang diketik pengguna. |
| `LOOKUP` | Dibaca dari tabel lain, bukan diketik pengguna. |
| `HITUNG` | Dihitung program saat penilaian dijalankan. |

Kolom "Wajib" mengikuti apa yang dipaksakan database:

- **Ya** — `NOT NULL`, pasti ditolak kalau kosong.
- **Bersyarat** — boleh kosong, tapi wajib ada pada keadaan tertentu. Sebagian dipaksakan `CHECK`, sebagian hanya dijaga program. Kolom mana yang mana, disebutkan di kolom catatan.
- **Tidak** — boleh kosong.

---

## Peta relasi

```
                        PENGETAHUAN BIDAN (terisi sejak awal)
  variabel ──1:N──> himpunan ──1:N──> aturan
  (5 baris)         (15 baris)        (243 baris)
                         ▲                 │
                         │                 │
      paparan        (dirujuk 5x           │
      (9 baris)       sebagai syarat,      │
                      1x sebagai           │
      kategori_hasil  kesimpulan)          │
      (5 baris)                            │
         ┊                                 │
         ┊ dicocokkan lewat kode           │ 1:N
         ┊ (tanpa foreign key)             │
         ▼                                 ▼
  pengguna ──1:N──> penilaian ──1:N──> penilaian_aturan
                        PEMAKAIAN SEHARI-HARI (bertambah terus)
```

### Sembilan foreign key, lengkap

| No | Dari | Ke | Saat induk dihapus |
|---|---|---|---|
| 1 | `himpunan.variabel_id` | `variabel.id` | `CASCADE` — himpunan ikut terhapus |
| 2 | `aturan.himpunan_haid_id` | `himpunan.id` | ditolak |
| 3 | `aturan.himpunan_mual_id` | `himpunan.id` | ditolak |
| 4 | `aturan.himpunan_nyeri_id` | `himpunan.id` | ditolak |
| 5 | `aturan.himpunan_bak_id` | `himpunan.id` | ditolak |
| 6 | `aturan.himpunan_hasil_id` | `himpunan.id` | ditolak |
| 7 | `penilaian.pengguna_id` | `pengguna.id` | ditolak |
| 8 | `penilaian_aturan.penilaian_id` | `penilaian.id` | `CASCADE` — jejak ikut terhapus |
| 9 | `penilaian_aturan.aturan_id` | `aturan.id` | ditolak |

### Tiga hubungan yang TIDAK pakai foreign key

Ini sengaja, bukan kelalaian. Alasannya ada di kolom terakhir.

| Dari | Ke | Kenapa bukan foreign key |
|---|---|---|
| `penilaian.pengaman` + `penilaian.keluar_dalam` | `paparan.(pengaman, keluar_dalam)` | Kolom di `penilaian` punya pilihan tambahan `tidak_dijawab` yang tidak ada di tabel `paparan`. Foreign key akan menolak baris yang pertanyaannya dilewati. |
| `penilaian.kategori` | `kategori_hasil.kode` | `kategori_hasil.kode` punya 5 pilihan, `penilaian.kategori` hanya 3. Pencocokannya dilakukan program. |
| `aturan.tingkat_paparan` | `paparan.tingkat` | `paparan.tingkat` tidak unik (3 nilai tersebar di 9 baris), jadi tidak bisa jadi tujuan foreign key. Keduanya memakai `ENUM` dengan pilihan yang sama. |

---

## Urutan pengisian tabel

Kalau mengisi manual, ikuti urutan ini. Membalik urutannya akan ditolak foreign key.

1. `variabel` — harus lebih dulu, karena `himpunan` menunjuk ke sini
2. `himpunan` — harus lebih dulu, karena `aturan` menunjuk ke sini
3. `paparan`, `kategori_hasil`, `pengguna` — bebas, tidak bergantung pada tabel lain
4. `aturan` — butuh `himpunan` sudah terisi
5. `penilaian` — butuh `pengguna` sudah terisi
6. `penilaian_aturan` — butuh `penilaian` dan `aturan` sudah terisi

---

# Tabel 1 — `pengguna`

Akun. Kolom `peran` yang membedakan siapa boleh mengubah pengetahuan.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | INT | Ya | `OTOMATIS` | Dirujuk `penilaian.pengguna_id` |
| `nama` | VARCHAR(100) | Ya | `PENGGUNA` | Dari form pendaftaran |
| `email` | VARCHAR(190) | Ya | `PENGGUNA` | Unik. Dipakai untuk masuk |
| `kata_sandi` | VARCHAR(255) | Ya | `PENGGUNA` | Simpan hasil hash, jangan teks asli |
| `peran` | ENUM | Ya | `AWAL` | `pengguna` atau `bidan`. Default `pengguna` |
| `dibuat_pada` | DATETIME | Ya | `OTOMATIS` | Default waktu sekarang |

---

# Tabel 2 — `variabel`

Daftar pertanyaan. 5 baris: `HAID`, `MUAL`, `NYERI`, `BAK` (jenis input) dan `HASIL` (jenis output).

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | INT | Ya | `OTOMATIS` | Dirujuk `himpunan.variabel_id` |
| `kode` | VARCHAR(20) | Ya | `AWAL` | Unik. Dipakai program untuk memanggil variabel |
| `nama` | VARCHAR(80) | Ya | `AWAL` | Teks yang tampil di form |
| `satuan` | VARCHAR(30) | Tidak | `AWAL` | Contoh: hari, kali/hari |
| `nilai_min` | DECIMAL(6,2) | Ya | `AWAL` | **Dipakai program untuk memvalidasi jawaban pengguna** |
| `nilai_maks` | DECIMAL(6,2) | Ya | `AWAL` | Sama. `CHECK` memaksa `nilai_min < nilai_maks` |
| `jenis` | ENUM | Ya | `AWAL` | `input` atau `output` |
| `urutan` | TINYINT | Ya | `AWAL` | Urutan tampil dan urutan syarat di `aturan.kode` |

---

# Tabel 3 — `himpunan`

Batas tiap tingkatan. 15 baris: 12 untuk gejala, 3 untuk keluaran.

Tabel ini memakai kolom berbeda tergantung jenis variabelnya. Inilah satu-satunya tempat di skema yang begitu, jadi perhatikan baik-baik.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | INT | Ya | `OTOMATIS` | Dirujuk `aturan` di **6 kolom** sekaligus |
| `variabel_id` | INT | Ya | `AWAL` | → `variabel.id` |
| `kode` | VARCHAR(20) | Ya | `AWAL` | Unik per variabel. Jadi `MUAL.SEDANG` dan `NYERI.SEDANG` boleh sama-sama bernama `SEDANG` |
| `nama` | VARCHAR(40) | Ya | `AWAL` | Teks yang tampil |
| `bentuk` | ENUM | Ya | `AWAL` | `trapesium` untuk gejala; `naik` atau `turun` untuk keluaran |
| `a` `b` `c` `d` | DECIMAL(6,2) | Bersyarat | `AWAL` | **Wajib untuk 12 himpunan gejala, kosong untuk 3 himpunan keluaran.** `CHECK` memaksa `a <= b <= c <= d` bila diisi, tapi tidak memaksa keberadaannya |
| `batas_bawah` | DECIMAL(6,2) | Bersyarat | `AWAL` | **Wajib untuk 3 himpunan keluaran, kosong untuk gejala.** Dipakai rumus balik Tsukamoto |
| `batas_atas` | DECIMAL(6,2) | Bersyarat | `AWAL` | Sama. `CHECK` memaksa `batas_bawah < batas_atas` bila diisi |
| `bobot` | TINYINT | Bersyarat | `AWAL` | **Wajib untuk 12 himpunan gejala, kosong untuk keluaran.** Hanya dipakai sekali untuk menyusun aturan, **tidak dipakai saat menghitung skor** |
| `urutan` | TINYINT | Ya | `AWAL` | Urutan tingkatan dari paling ringan |

### Isi kolom untuk 3 himpunan keluaran

Dari dua kolom batas inilah rumus balik dihitung. Kalau salah satu kosong, nilai `z` tidak bisa dicari.

| `kode` | `bentuk` | `batas_bawah` | `batas_atas` | Rumus balik yang dihasilkan |
|---|---|---|---|---|
| `RENDAH` | `turun` | 0 | 40 | `z = 40 − 40 × alfa` |
| `SEDANG` | `naik` | 30 | 70 | `z = 30 + 40 × alfa` |
| `TINGGI` | `naik` | 60 | 100 | `z = 60 + 40 × alfa` |

---

# Tabel 4 — `paparan`

9 baris, tabel pencarian murni. Tidak dirujuk tabel mana pun lewat foreign key; program yang membacanya.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | INT | Ya | `OTOMATIS` | Tidak dirujuk tabel lain |
| `pengaman` | ENUM | Ya | `AWAL` | Dicocokkan dengan `penilaian.pengaman` |
| `keluar_dalam` | ENUM | Ya | `AWAL` | Dicocokkan dengan `penilaian.keluar_dalam` |
| `tingkat` | ENUM | Ya | `AWAL` | **Hasil pencarian.** Disalin program ke `penilaian.tingkat_paparan` |
| `catatan` | VARCHAR(190) | Tidak | `AWAL` | Alasan sel tertentu, untuk dokumentasi |

Cara program memakainya:

```sql
SELECT tingkat FROM paparan
WHERE pengaman = ? AND keluar_dalam = ?;
```

---

# Tabel 5 — `aturan`

243 baris, semuanya dibangkitkan satu query `INSERT ... SELECT`, bukan ditulis tangan.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | SMALLINT | Ya | `OTOMATIS` | Dirujuk `penilaian_aturan.aturan_id` |
| `kode` | VARCHAR(96) | Ya | `HITUNG` | Unik. Gabungan kode kelima syarat, contoh `AGAK_TELAT-SEDANG-BERAT-MENINGKAT-SEDANG` |
| `himpunan_haid_id` | INT | Ya | `LOOKUP` | → `himpunan.id`, hanya himpunan milik variabel `HAID` |
| `himpunan_mual_id` | INT | Ya | `LOOKUP` | → `himpunan.id`, variabel `MUAL` |
| `himpunan_nyeri_id` | INT | Ya | `LOOKUP` | → `himpunan.id`, variabel `NYERI` |
| `himpunan_bak_id` | INT | Ya | `LOOKUP` | → `himpunan.id`, variabel `BAK` |
| `tingkat_paparan` | ENUM | Ya | `HITUNG` | Syarat kelima. Lihat catatan hubungan tanpa foreign key di atas |
| `himpunan_hasil_id` | INT | Ya | `HITUNG` | → `himpunan.id`, hanya himpunan milik variabel `HASIL`. Diambil dari matriks kesimpulan |
| `bobot_gejala` | TINYINT | Ya | `HITUNG` | Jumlah `himpunan.bobot` keempat gejala, nilainya 0 sampai 10 |
| `kekuatan_gejala` | ENUM | Ya | `HITUNG` | Dari `bobot_gejala`: 0–2 rendah, 3–5 sedang, 6–10 tinggi |

Dua jaminan penting dari kunci unik di tabel ini:

- `uq_aturan_kode` — satu kode hanya boleh ada sekali
- `uq_aturan_syarat` — kombinasi kelima kolom syarat harus unik, **inilah yang membuat aturan kembar atau bertentangan tidak bisa masuk dua kali**

Dua kolom terakhir (`bobot_gejala`, `kekuatan_gejala`) sebenarnya bisa dihitung ulang kapan saja. Disimpan supaya sifat monoton basis aturan bisa diperiksa dengan satu query, tanpa menghitung ulang 243 baris.

---

# Tabel 6 — `kategori_hasil`

5 baris. Semua teks yang dibaca pengguna ada di sini, termasuk dua keadaan yang tidak punya skor.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | INT | Ya | `OTOMATIS` | Tidak dirujuk tabel lain |
| `kode` | ENUM | Ya | `AWAL` | Unik. 5 pilihan: 3 kategori skor + `belum_bisa_dinilai` + `tanpa_riwayat_hubungan` |
| `skor_min` | TINYINT | Bersyarat | `AWAL` | **Kosong untuk 2 baris keadaan tanpa skor.** Terisi untuk 3 kategori: 0, 40, 71 |
| `skor_maks` | TINYINT | Bersyarat | `AWAL` | Sama: 39, 70, 100. `CHECK` memaksa `skor_min <= skor_maks <= 100` |
| `judul` | VARCHAR(80) | Ya | `AWAL` | Judul yang tampil, contoh "Indikasi kuat" |
| `saran` | TEXT | Ya | `AWAL` | Isi saran |
| `peringatan` | VARCHAR(190) | Ya | `AWAL` | Kalimat "hasil bukan diagnosis". Wajib tampil di setiap hasil |

Cara program memakainya, dua jalur:

```sql
-- kalau penilaian selesai, cocokkan skornya ke rentang
SELECT judul, saran, peringatan FROM kategori_hasil
WHERE ? BETWEEN skor_min AND skor_maks;

-- kalau gerbang tidak lolos, ambil langsung dari statusnya
SELECT judul, saran, peringatan FROM kategori_hasil
WHERE kode = ?;   -- 'belum_bisa_dinilai' atau 'tanpa_riwayat_hubungan'
```

---

# Tabel 7 — `penilaian`

Satu baris per pengisian kuesioner. Di tabel inilah ketiga asal nilai bercampur, jadi saya pisah per kelompok.

### Kelompok A — identitas

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `id` | INT | Ya | `OTOMATIS` | Dirujuk `penilaian_aturan.penilaian_id` |
| `pengguna_id` | INT | Ya | `PENGGUNA` | → `pengguna.id`. Dari sesi yang sedang masuk, bukan diketik |
| `diisi_pada` | DATETIME | Ya | `OTOMATIS` | Default waktu sekarang |

### Kelompok B — 4 jawaban gejala

Keempatnya wajib. Program memvalidasinya terhadap `variabel.nilai_min` dan `variabel.nilai_maks` sebelum menyimpan.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `telat_haid` | DECIMAL(5,1) | Ya | `PENGGUNA` | Hari. Divalidasi ke rentang variabel `HAID` (0–60) |
| `mual` | DECIMAL(5,1) | Ya | `PENGGUNA` | Kali/hari. Rentang variabel `MUAL` (0–10) |
| `nyeri_payudara` | DECIMAL(5,1) | Ya | `PENGGUNA` | Skala. Rentang variabel `NYERI` (0–10) |
| `berkemih` | DECIMAL(5,1) | Ya | `PENGGUNA` | Kali/hari. Rentang variabel `BAK` (4–20) |

### Kelompok C — 3 jawaban riwayat paparan

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `belum_pernah_hubungan` | TINYINT(1) | Ya | `PENGGUNA` | Default 0. Bila 1, `status` harus `tanpa_riwayat_hubungan` |
| `hari_sejak_hubungan` | SMALLINT | Bersyarat | `PENGGUNA` | **Kosong hanya bila `belum_pernah_hubungan` = 1.** Dipakai gerbang 7 hari |
| `pengaman` | ENUM | Ya | `PENGGUNA` | Default `tidak_dijawab`. Baris tabel `paparan` |
| `keluar_dalam` | ENUM | Ya | `PENGGUNA` | Default `tidak_dijawab`. Kolom tabel `paparan` |
| `tingkat_paparan` | ENUM | Bersyarat | `LOOKUP` | **Hasil baca tabel `paparan`.** Wajib ada bila `status` = `selesai`, karena jadi syarat kelima saat mencocokkan aturan. Tidak dipaksakan `CHECK`, program yang menjaga |

### Kelompok D — hasil gerbang 7 hari

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `status` | ENUM | Ya | `HITUNG` | `selesai`, `belum_bisa_dinilai`, atau `tanpa_riwayat_hubungan`. **Kolom penentu di tabel ini** |
| `tanggal_uji_awal` | DATE | Bersyarat | `HITUNG` | Tanggal hubungan + 14 hari. Hanya terisi bila `status` = `belum_bisa_dinilai` |

### Kelompok E — hasil perhitungan

Keempatnya kosong bila gerbang tidak lolos. Dua yang pertama dipaksakan `CHECK`.

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `skor_mentah` | DECIMAL(7,4) | Bersyarat | `HITUNG` | Hasil `SUM(alfa × z) / SUM(alfa)` sebelum dibulatkan, contoh `72.5000` |
| `skor` | TINYINT | Bersyarat | `HITUNG` | Hasil pembulatan setengah ke atas, contoh `73`. **Dipaksakan `CHECK`: wajib ada bila `status` = `selesai`, wajib kosong bila tidak** |
| `kategori` | ENUM | Bersyarat | `LOOKUP` | Dicocokkan dari `skor` ke rentang di `kategori_hasil`. **Dipaksakan `CHECK` yang sama** |
| `jumlah_aturan_aktif` | SMALLINT | Tidak | `HITUNG` | Sama dengan jumlah baris `penilaian_aturan` milik penilaian ini. Disimpan agar tidak perlu `COUNT` setiap membuka daftar riwayat |

### Isi `CHECK` yang paling penting di skema ini

```sql
CONSTRAINT ck_penilaian_skor CHECK (
     (status =  'selesai' AND skor IS NOT NULL AND kategori IS NOT NULL)
  OR (status <> 'selesai' AND skor IS NULL     AND kategori IS NULL)
)
```

Ini menutup satu kesalahan yang berbahaya: menyimpan angka rendah untuk penilaian yang sebenarnya **belum bisa dinilai**. Pengguna akan membaca angka rendah sebagai "aman", padahal yang benar "belum bisa diketahui". Database menolaknya, jadi bug di program tidak bisa membuatnya lolos.

---

# Tabel 8 — `penilaian_aturan`

Jejak hitung. Satu baris per aturan yang aktif. **Inti metode Tsukamoto ada di tabel ini.**

| Kolom | Tipe | Wajib | Asal nilai | Relasi / catatan |
|---|---|---|---|---|
| `penilaian_id` | INT | Ya | `LOOKUP` | → `penilaian.id`. Bagian kunci utama |
| `aturan_id` | SMALLINT | Ya | `LOOKUP` | → `aturan.id`. Bagian kunci utama, jadi satu aturan hanya boleh tercatat sekali per penilaian |
| `alfa` | DECIMAL(5,4) | Ya | `HITUNG` | Nilai terkecil dari kelima syarat. `CHECK` memaksa `0 < alfa <= 1`, jadi aturan yang tidak aktif tidak bisa ikut tersimpan |
| `z` | DECIMAL(7,4) | Ya | `HITUNG` | Hasil membalik rumus himpunan keluaran. **Wajib disimpan**, lihat catatan di bawah |

### Kenapa `z` wajib disimpan

Pada Mamdani, tiap kesimpulan punya satu nilai tetap, jadi `z` bisa dicari ulang dari tabel himpunan kapan saja. Pada Tsukamoto tidak begitu: `z` dihitung dari `alfa`, dan `alfa` berbeda tiap orang. Aturan yang sama bisa memberi `z = 80` untuk satu pengguna dan `z = 65` untuk pengguna lain.

Kalau `z` tidak disimpan, hasil lama tidak bisa diperiksa ulang — dan kalau bidan nanti menggeser `batas_bawah`/`batas_atas` di tabel `himpunan`, seluruh riwayat lama akan terbaca salah.

Cara memeriksanya sudah disiapkan sebagai view `v_cek_z`:

```sql
CASE o.bentuk
  WHEN 'naik'  THEN o.batas_bawah + (o.batas_atas - o.batas_bawah) * pa.alfa
  WHEN 'turun' THEN o.batas_atas  - (o.batas_atas - o.batas_bawah) * pa.alfa
END
```

---

## Perjalanan satu penilaian, kolom demi kolom

Contoh nyata: telat haid 18 hari, mual 6×/hari, nyeri 7, berkemih 11×/hari, hubungan terakhir 20 hari lalu, selalu pakai pengaman, ejakulasi di dalam.

| Urutan | Yang terjadi | Kolom yang terisi | Nilainya |
|---|---|---|---|
| 1 | Pengguna menekan kirim | `pengguna_id`, `diisi_pada` | dari sesi, waktu sekarang |
| 2 | Jawaban gejala disimpan, divalidasi ke `variabel` | `telat_haid`, `mual`, `nyeri_payudara`, `berkemih` | 18, 6, 7, 11 |
| 3 | Jawaban riwayat disimpan | `hari_sejak_hubungan`, `pengaman`, `keluar_dalam` | 20, selalu, ya |
| 4 | **Gerbang 7 hari.** 20 ≥ 7, lolos | `status` | `selesai` |
| 5 | Baca tabel `paparan` baris (selalu, ya) | `tingkat_paparan` | `sedang` |
| 6 | Fuzzifikasi memakai kolom `a,b,c,d` di `himpunan` | — belum ada kolom yang terisi | μ: 1,0 / 0,5 / 0,5 / 0,5 / 0,5 / 1,0 |
| 7 | Cari aturan yang cocok di `aturan`, hitung alfa | `penilaian_aturan.alfa` × 4 baris | semuanya 0,5 |
| 8 | Rumus balik memakai `batas_bawah`/`batas_atas` | `penilaian_aturan.z` × 4 baris | 50, 80, 80, 80 |
| 9 | Rata-rata terbobot | `skor_mentah`, `jumlah_aturan_aktif` | 72,5 dan 4 |
| 10 | Pembulatan setengah ke atas | `skor` | 73 |
| 11 | Cocokkan 73 ke rentang di `kategori_hasil` | `kategori` | `tinggi` (rentang 71–100) |

Perhatikan langkah 6: fuzzifikasi tidak menyimpan apa pun. Nilai μ hanya dipakai sesaat untuk menghitung `alfa`. Kalau Anda ingin menyimpannya juga untuk keperluan skripsi, tambahkan satu tabel `penilaian_himpunan` berisi `penilaian_id`, `himpunan_id`, dan `mu` — tapi skema ini sengaja tidak memasukkannya supaya tetap 8 tabel.

---

## Enam kesalahan yang paling sering terjadi

1. **Lupa menyimpan `z`.** Hasil lama jadi tidak bisa diperiksa. Lihat bagian Tabel 8.
2. **Mengisi `skor` padahal `status` bukan `selesai`.** Ditolak `ck_penilaian_skor`, dan memang seharusnya ditolak.
3. **Lupa mengisi `tingkat_paparan` padahal status `selesai`.** Database tidak menolaknya, tapi aturan tidak akan ketemu karena syarat kelimanya kosong. Jaga ini di program.
4. **Memberi himpunan keluaran bentuk `trapesium`.** Rumus balik tidak lagi memberi satu jawaban pasti, dan metodenya bukan Tsukamoto lagi. `bentuk` untuk variabel `HASIL` hanya boleh `naik` atau `turun`.
5. **Memakai kolom `bobot` saat menghitung skor.** Kolom itu hanya untuk menyusun 243 aturan. Yang dipakai menghitung adalah `a,b,c,d` dan `batas_bawah`/`batas_atas`.
6. **Menyimpan aturan dengan `alfa` = 0.** Ditolak `ck_pa_alfa`. Simpan hanya aturan yang benar-benar aktif.

---

## Query untuk memeriksa isi database

```sql
-- Apakah data awal lengkap? Harus 5, 15, 9, 243, 5
SELECT 'variabel' AS tabel, COUNT(*) FROM variabel
UNION ALL SELECT 'himpunan',       COUNT(*) FROM himpunan
UNION ALL SELECT 'paparan',        COUNT(*) FROM paparan
UNION ALL SELECT 'aturan',         COUNT(*) FROM aturan
UNION ALL SELECT 'kategori_hasil', COUNT(*) FROM kategori_hasil;

-- Apakah ada himpunan gejala yang batasnya belum diisi? Harus kosong
SELECT h.kode FROM himpunan h JOIN variabel v ON v.id = h.variabel_id
WHERE v.jenis = 'input' AND (h.a IS NULL OR h.bobot IS NULL);

-- Apakah ada himpunan keluaran yang tidak monoton? Harus kosong
SELECT h.kode FROM himpunan h JOIN variabel v ON v.id = h.variabel_id
WHERE v.jenis = 'output'
  AND (h.bentuk NOT IN ('naik','turun') OR h.batas_bawah IS NULL OR h.batas_atas IS NULL);

-- Apakah ada penilaian selesai yang tidak punya jejak hitung? Harus kosong
SELECT p.id FROM penilaian p
LEFT JOIN penilaian_aturan pa ON pa.penilaian_id = p.id
WHERE p.status = 'selesai' AND pa.penilaian_id IS NULL;

-- Apakah skor tersimpan sama dengan hasil hitung ulang?
SELECT * FROM v_hitung_ulang;

-- Apakah z tersimpan sama dengan hasil rumus balik?
SELECT * FROM v_cek_z;
```

---

## Berkas terkait

| Berkas | Isinya |
|---|---|
| `database/schema.sql` | Skema siap jalan: 8 tabel, 3 view, data awal, pembangkit 243 aturan, dan satu contoh penilaian |
| `database/prompt-skema.sql` | Spesifikasi yang sama dalam bentuk perintah, untuk diminta ulang ke asisten AI |
| `database/SKEMA.md` | Dokumen ini |
