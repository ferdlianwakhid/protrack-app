-- =====================================================================
-- SKEMA DATABASE: Deteksi Kehamilan Dini dengan Fuzzy Tsukamoto
--
-- Target : MySQL 8.0.16+ atau MariaDB 10.5+
-- Isi    : 8 tabel, 3 view bantu, data awal, dan pembangkit 243 aturan
--
-- Cara baca singkat:
--   Tabel 1-5 = pengetahuan bidan (jarang berubah)
--   Tabel 6-7 = hasil pengisian kuesioner (bertambah terus)
--   Tabel 8   = teks saran yang dilihat pengguna
--
-- Kenapa Tsukamoto, bukan Mamdani:
--   Pada Tsukamoto, tiap aturan menghasilkan satu angka z sendiri. Angka itu
--   dicari dengan MEMBALIK rumus himpunan keluaran. Karena itu himpunan
--   keluaran harus monoton (naik terus atau turun terus), dan nilai z TIDAK
--   tetap: dia ikut berubah mengikuti alfa. Jadi z hasil hitungan wajib
--   disimpan di tabel penilaian_aturan, bukan hanya diambil dari tabel
--   himpunan.
-- =====================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
DROP VIEW  IF EXISTS v_cek_z;
DROP VIEW  IF EXISTS v_hitung_ulang;
DROP VIEW  IF EXISTS v_aturan_terbaca;
DROP TABLE IF EXISTS penilaian_aturan;
DROP TABLE IF EXISTS penilaian;
DROP TABLE IF EXISTS aturan;
DROP TABLE IF EXISTS kategori_hasil;
DROP TABLE IF EXISTS paparan;
DROP TABLE IF EXISTS himpunan;
DROP TABLE IF EXISTS variabel;
DROP TABLE IF EXISTS pengguna;
SET FOREIGN_KEY_CHECKS = 1;


-- ---------------------------------------------------------------------
-- 1. pengguna
-- ---------------------------------------------------------------------
CREATE TABLE pengguna (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  nama          VARCHAR(100) NOT NULL,
  email         VARCHAR(190) NOT NULL,
  kata_sandi    VARCHAR(255) NOT NULL COMMENT 'simpan hasil hash, jangan teks asli',
  peran         ENUM('pengguna','bidan') NOT NULL DEFAULT 'pengguna',
  dibuat_pada   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_pengguna_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Akun. Peran bidan boleh mengubah himpunan dan aturan.';


-- ---------------------------------------------------------------------
-- 2. variabel
-- ---------------------------------------------------------------------
CREATE TABLE variabel (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  kode        VARCHAR(20)  NOT NULL COMMENT 'HAID, MUAL, NYERI, BAK, HASIL',
  nama        VARCHAR(80)  NOT NULL,
  satuan      VARCHAR(30)  NULL,
  nilai_min   DECIMAL(6,2) NOT NULL,
  nilai_maks  DECIMAL(6,2) NOT NULL,
  jenis       ENUM('input','output') NOT NULL,
  urutan      TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_variabel_kode (kode),
  CONSTRAINT ck_variabel_rentang CHECK (nilai_min < nilai_maks)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='4 pertanyaan gejala (input) dan 1 hasil (output).';


-- ---------------------------------------------------------------------
-- 3. himpunan
--    Untuk variabel input : pakai kolom a, b, c, d (bentuk trapesium).
--      Artinya: nilai di bawah a dan di atas d dianggap 0; naik dari a ke b;
--      penuh (1) dari b sampai c; turun dari c ke d.
--    Untuk variabel output: pakai kolom bentuk + batas_bawah + batas_atas.
--      Dari dua batas itu rumus baliknya dihitung:
--        bentuk naik  ->  z = batas_bawah + (batas_atas - batas_bawah) * alfa
--        bentuk turun ->  z = batas_atas  - (batas_atas - batas_bawah) * alfa
-- ---------------------------------------------------------------------
CREATE TABLE himpunan (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  variabel_id   INT UNSIGNED NOT NULL,
  kode          VARCHAR(20)  NOT NULL COMMENT 'AGAK_TELAT, SEDANG, BERAT, dst',
  nama          VARCHAR(40)  NOT NULL,
  bentuk        ENUM('trapesium','naik','turun') NOT NULL DEFAULT 'trapesium',
  a             DECIMAL(6,2) NULL,
  b             DECIMAL(6,2) NULL,
  c             DECIMAL(6,2) NULL,
  d             DECIMAL(6,2) NULL,
  batas_bawah   DECIMAL(6,2) NULL COMMENT 'khusus himpunan output',
  batas_atas    DECIMAL(6,2) NULL COMMENT 'khusus himpunan output',
  bobot         TINYINT UNSIGNED NULL
                  COMMENT 'Hanya dipakai sekali untuk MENYUSUN aturan, tidak dipakai saat menghitung',
  urutan        TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_himpunan_kode (variabel_id, kode),
  CONSTRAINT fk_himpunan_variabel FOREIGN KEY (variabel_id) REFERENCES variabel (id) ON DELETE CASCADE,
  CONSTRAINT ck_himpunan_trapesium CHECK (a IS NULL OR (a <= b AND b <= c AND c <= d)),
  CONSTRAINT ck_himpunan_output CHECK (batas_bawah IS NULL OR batas_bawah < batas_atas)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Batas tiap himpunan fuzzy. Diubah bidan tanpa menyentuh kode program.';


-- ---------------------------------------------------------------------
-- 4. paparan
--    9 kombinasi jawaban, hasilnya satu tingkat. Nilai tegas, bukan fuzzy,
--    karena jawaban ya/tidak tidak punya derajat keanggotaan.
-- ---------------------------------------------------------------------
CREATE TABLE paparan (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  pengaman      ENUM('selalu','kadang','tidak') NOT NULL,
  keluar_dalam  ENUM('tidak','tidak_yakin','ya') NOT NULL,
  tingkat       ENUM('rendah','sedang','tinggi') NOT NULL,
  catatan       VARCHAR(190) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_paparan_kombinasi (pengaman, keluar_dalam)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Ejakulasi di dalam tidak pernah menghasilkan tingkat rendah.';


-- ---------------------------------------------------------------------
-- 5. aturan
--    243 baris. Lima kolom syarat dibuat sejajar supaya mudah dibaca dan
--    mudah dicari. UNIQUE pada kelima kolom itu yang mencegah aturan kembar.
-- ---------------------------------------------------------------------
CREATE TABLE aturan (
  id                 SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  kode               VARCHAR(96)  NOT NULL COMMENT 'gabungan kode kelima syarat, enak dibaca manusia',
  himpunan_haid_id   INT UNSIGNED NOT NULL,
  himpunan_mual_id   INT UNSIGNED NOT NULL,
  himpunan_nyeri_id  INT UNSIGNED NOT NULL,
  himpunan_bak_id    INT UNSIGNED NOT NULL,
  tingkat_paparan    ENUM('rendah','sedang','tinggi') NOT NULL,
  himpunan_hasil_id  INT UNSIGNED NOT NULL COMMENT 'kesimpulan: RENDAH, SEDANG, atau TINGGI',
  bobot_gejala       TINYINT UNSIGNED NOT NULL COMMENT 'jumlah bobot 4 gejala, 0 sampai 10',
  kekuatan_gejala    ENUM('rendah','sedang','tinggi') NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_aturan_kode (kode),
  UNIQUE KEY uq_aturan_syarat (himpunan_haid_id, himpunan_mual_id,
                               himpunan_nyeri_id, himpunan_bak_id, tingkat_paparan),
  KEY ix_aturan_hasil (himpunan_hasil_id),
  CONSTRAINT fk_aturan_haid  FOREIGN KEY (himpunan_haid_id)  REFERENCES himpunan (id),
  CONSTRAINT fk_aturan_mual  FOREIGN KEY (himpunan_mual_id)  REFERENCES himpunan (id),
  CONSTRAINT fk_aturan_nyeri FOREIGN KEY (himpunan_nyeri_id) REFERENCES himpunan (id),
  CONSTRAINT fk_aturan_bak   FOREIGN KEY (himpunan_bak_id)   REFERENCES himpunan (id),
  CONSTRAINT fk_aturan_hasil FOREIGN KEY (himpunan_hasil_id) REFERENCES himpunan (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='JIKA haid=... DAN mual=... DAN nyeri=... DAN bak=... DAN paparan=... MAKA hasil=...';


-- ---------------------------------------------------------------------
-- 6. kategori_hasil
--    Satu tabel untuk semua teks yang dilihat pengguna, termasuk dua keadaan
--    yang tidak punya skor.
-- ---------------------------------------------------------------------
CREATE TABLE kategori_hasil (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  kode        ENUM('rendah','sedang','tinggi','belum_bisa_dinilai','tanpa_riwayat_hubungan') NOT NULL,
  skor_min    TINYINT UNSIGNED NULL COMMENT 'kosong untuk keadaan tanpa skor',
  skor_maks   TINYINT UNSIGNED NULL,
  judul       VARCHAR(80)  NOT NULL,
  saran       TEXT         NOT NULL,
  peringatan  VARCHAR(190) NOT NULL COMMENT 'wajib tampil: hasil bukan diagnosis',
  PRIMARY KEY (id),
  UNIQUE KEY uq_kategori_kode (kode),
  CONSTRAINT ck_kategori_rentang CHECK (skor_min IS NULL OR (skor_min <= skor_maks AND skor_maks <= 100))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Ambang skor dan teks saran.';


-- ---------------------------------------------------------------------
-- 7. penilaian
--    Satu baris per pengisian kuesioner: jawaban mentah + hasil akhirnya.
-- ---------------------------------------------------------------------
CREATE TABLE penilaian (
  id                      INT UNSIGNED NOT NULL AUTO_INCREMENT,
  pengguna_id             INT UNSIGNED NOT NULL,
  diisi_pada              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- jawaban 4 gejala
  telat_haid              DECIMAL(5,1) NOT NULL COMMENT 'hari',
  mual                    DECIMAL(5,1) NOT NULL COMMENT 'kali per hari',
  nyeri_payudara          DECIMAL(5,1) NOT NULL COMMENT 'skala 0-10',
  berkemih                DECIMAL(5,1) NOT NULL COMMENT 'kali per hari',

  -- jawaban 3 riwayat
  belum_pernah_hubungan   TINYINT(1)   NOT NULL DEFAULT 0,
  hari_sejak_hubungan     SMALLINT UNSIGNED NULL,
  pengaman                ENUM('selalu','kadang','tidak','tidak_dijawab') NOT NULL DEFAULT 'tidak_dijawab',
  keluar_dalam            ENUM('tidak','tidak_yakin','ya','tidak_dijawab') NOT NULL DEFAULT 'tidak_dijawab',
  tingkat_paparan         ENUM('rendah','sedang','tinggi') NULL COMMENT 'hasil tabel paparan',

  -- gerbang 7 hari
  status                  ENUM('selesai','belum_bisa_dinilai','tanpa_riwayat_hubungan') NOT NULL,
  tanggal_uji_awal        DATE         NULL COMMENT 'tanggal hubungan + 14 hari',

  -- hasil
  skor_mentah             DECIMAL(7,4) NULL COMMENT 'sebelum dibulatkan, mis. 72.5000',
  skor                    TINYINT UNSIGNED NULL COMMENT 'sudah dibulatkan, mis. 73',
  kategori                ENUM('rendah','sedang','tinggi') NULL,
  jumlah_aturan_aktif     SMALLINT UNSIGNED NULL,

  PRIMARY KEY (id),
  KEY ix_penilaian_pengguna (pengguna_id, diisi_pada),
  CONSTRAINT fk_penilaian_pengguna FOREIGN KEY (pengguna_id) REFERENCES pengguna (id),
  -- Aturan penting: kalau gerbang 7 hari tidak lolos, baris ini WAJIB tanpa skor.
  CONSTRAINT ck_penilaian_skor CHECK (
       (status =  'selesai' AND skor IS NOT NULL AND kategori IS NOT NULL)
    OR (status <> 'selesai' AND skor IS NULL     AND kategori IS NULL)
  ),
  CONSTRAINT ck_penilaian_batas CHECK (skor IS NULL OR skor <= 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Riwayat pengisian kuesioner beserta hasilnya.';


-- ---------------------------------------------------------------------
-- 8. penilaian_aturan
--    Jejak hitung. Inti metode Tsukamoto ada di sini: tiap aturan yang aktif
--    punya alfa dan z-nya sendiri. Dari tabel ini skor bisa dihitung ulang.
-- ---------------------------------------------------------------------
CREATE TABLE penilaian_aturan (
  penilaian_id  INT UNSIGNED      NOT NULL,
  aturan_id     SMALLINT UNSIGNED NOT NULL,
  alfa          DECIMAL(5,4)      NOT NULL COMMENT 'nilai terkecil dari 5 syarat',
  z             DECIMAL(7,4)      NOT NULL COMMENT 'hasil membalik rumus himpunan keluaran',
  PRIMARY KEY (penilaian_id, aturan_id),
  KEY ix_pa_aturan (aturan_id),
  CONSTRAINT fk_pa_penilaian FOREIGN KEY (penilaian_id) REFERENCES penilaian (id) ON DELETE CASCADE,
  CONSTRAINT fk_pa_aturan    FOREIGN KEY (aturan_id)    REFERENCES aturan (id),
  CONSTRAINT ck_pa_alfa CHECK (alfa > 0 AND alfa <= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Satu baris per aturan yang aktif pada satu penilaian.';


-- =====================================================================
-- VIEW BANTU
-- =====================================================================

-- Menampilkan 243 aturan sebagai kalimat, supaya enak diperiksa bidan.
CREATE OR REPLACE VIEW v_aturan_terbaca AS
SELECT  a.id,
        a.kode,
        CONCAT('JIKA telat haid = ', h.nama,
               ' DAN mual = ',        m.nama,
               ' DAN nyeri = ',       n.nama,
               ' DAN berkemih = ',    b.nama,
               ' DAN paparan = ',     a.tingkat_paparan,
               ' MAKA kemungkinan = ', o.nama)       AS kalimat,
        a.bobot_gejala,
        a.kekuatan_gejala,
        o.nama                                        AS kesimpulan
FROM    aturan a
JOIN    himpunan h ON h.id = a.himpunan_haid_id
JOIN    himpunan m ON m.id = a.himpunan_mual_id
JOIN    himpunan n ON n.id = a.himpunan_nyeri_id
JOIN    himpunan b ON b.id = a.himpunan_bak_id
JOIN    himpunan o ON o.id = a.himpunan_hasil_id;

-- Menghitung ulang skor dari jejak hitung: jumlah(alfa*z) / jumlah(alfa).
CREATE OR REPLACE VIEW v_hitung_ulang AS
SELECT  p.id                                       AS penilaian_id,
        p.skor_mentah                              AS skor_tersimpan,
        SUM(pa.alfa * pa.z) / SUM(pa.alfa)         AS skor_dihitung_ulang,
        ROUND(SUM(pa.alfa * pa.z) / SUM(pa.alfa))  AS skor_dibulatkan,
        SUM(pa.alfa * pa.z)                        AS pembilang,
        SUM(pa.alfa)                               AS penyebut,
        COUNT(*)                                   AS aturan_aktif
FROM    penilaian p
JOIN    penilaian_aturan pa ON pa.penilaian_id = p.id
GROUP BY p.id, p.skor_mentah;

-- Memeriksa nilai z: dihitung ulang dari alfa memakai batas himpunan keluaran.
-- Inilah rumus balik Tsukamoto, ditulis sebagai SQL.
CREATE OR REPLACE VIEW v_cek_z AS
SELECT  pa.penilaian_id,
        a.kode,
        pa.alfa,
        o.nama                                     AS kesimpulan,
        o.bentuk,
        pa.z                                       AS z_tersimpan,
        CASE o.bentuk
          WHEN 'naik'  THEN o.batas_bawah + (o.batas_atas - o.batas_bawah) * pa.alfa
          WHEN 'turun' THEN o.batas_atas  - (o.batas_atas - o.batas_bawah) * pa.alfa
        END                                        AS z_dihitung_ulang
FROM    penilaian_aturan pa
JOIN    aturan   a ON a.id = pa.aturan_id
JOIN    himpunan o ON o.id = a.himpunan_hasil_id;


-- =====================================================================
-- DATA AWAL
-- =====================================================================

INSERT INTO pengguna (nama, email, kata_sandi, peran) VALUES
  ('Bidan Pembina',  'bidan@contoh.test',    '$2y$10$ganti.saat.instalasi', 'bidan'),
  ('Contoh Pengguna','pengguna@contoh.test', '$2y$10$ganti.saat.instalasi', 'pengguna');

INSERT INTO variabel (kode, nama, satuan, nilai_min, nilai_maks, jenis, urutan) VALUES
  ('HAID',  'Keterlambatan haid',        'hari',       0,  60, 'input',  1),
  ('MUAL',  'Mual dan muntah',           'kali/hari',  0,  10, 'input',  2),
  ('NYERI', 'Nyeri payudara',            'skala 0-10', 0,  10, 'input',  3),
  ('BAK',   'Frekuensi berkemih',        'kali/hari',  4,  20, 'input',  4),
  ('HASIL', 'Kemungkinan hamil',         'skor',       0, 100, 'output', 1);

-- Himpunan variabel input. Kolom bobot dipakai nanti untuk menyusun aturan:
-- keterlambatan haid diberi bobot ganda (0/2/4) karena satu-satunya gejala
-- yang bisa berdiri sendiri sebagai indikasi; gejala lain 0/1/2.
INSERT INTO himpunan (variabel_id, kode, nama, bentuk, a, b, c, d, bobot, urutan)
SELECT v.id, x.kode, x.nama, 'trapesium', x.a, x.b, x.c, x.d, x.bobot, x.urutan
FROM   variabel v
JOIN (
            SELECT 'HAID'  AS vk, 'TEPAT_WAKTU' AS kode, 'Tepat waktu' AS nama,
                    0 AS a,  0 AS b,  5 AS c, 12 AS d, 0 AS bobot, 1 AS urutan
  UNION ALL SELECT 'HAID',  'AGAK_TELAT', 'Agak telat',  7, 14, 21, 28, 2, 2
  UNION ALL SELECT 'HAID',  'TELAT',      'Telat',      21, 35, 60, 60, 4, 3
  UNION ALL SELECT 'MUAL',  'RINGAN',     'Ringan',      0,  0,  1,  3, 0, 1
  UNION ALL SELECT 'MUAL',  'SEDANG',     'Sedang',      2,  4,  5,  7, 1, 2
  UNION ALL SELECT 'MUAL',  'BERAT',      'Berat',       5,  7, 10, 10, 2, 3
  UNION ALL SELECT 'NYERI', 'RINGAN',     'Ringan',      0,  0,  2,  5, 0, 1
  UNION ALL SELECT 'NYERI', 'SEDANG',     'Sedang',      3,  5,  6,  8, 1, 2
  UNION ALL SELECT 'NYERI', 'BERAT',      'Berat',       6,  8, 10, 10, 2, 3
  UNION ALL SELECT 'BAK',   'NORMAL',     'Normal',      4,  4,  6,  9, 0, 1
  UNION ALL SELECT 'BAK',   'MENINGKAT',  'Meningkat',   7, 10, 12, 15, 1, 2
  UNION ALL SELECT 'BAK',   'SERING',     'Sering',     12, 15, 20, 20, 2, 3
) x ON x.vk = v.kode;

-- Himpunan keluaran. WAJIB monoton untuk Tsukamoto.
--   RENDAH turun di 0-40    -> z = 40 - 40*alfa
--   SEDANG naik  di 30-70   -> z = 30 + 40*alfa
--   TINGGI naik  di 60-100  -> z = 60 + 40*alfa
INSERT INTO himpunan (variabel_id, kode, nama, bentuk, batas_bawah, batas_atas, urutan)
SELECT v.id, x.kode, x.nama, x.bentuk, x.bawah, x.atas, x.urutan
FROM   variabel v
JOIN (
            SELECT 'RENDAH' AS kode, 'Rendah' AS nama, 'turun' AS bentuk,
                    0 AS bawah,  40 AS atas, 1 AS urutan
  UNION ALL SELECT 'SEDANG', 'Sedang', 'naik', 30,  70, 2
  UNION ALL SELECT 'TINGGI', 'Tinggi', 'naik', 60, 100, 3
) x ON v.kode = 'HASIL';

INSERT INTO paparan (pengaman, keluar_dalam, tingkat, catatan) VALUES
  ('selalu', 'tidak',       'rendah', NULL),
  ('selalu', 'tidak_yakin', 'rendah', NULL),
  ('selalu', 'ya',          'sedang', 'Kontrasepsi punya angka kegagalan'),
  ('kadang', 'tidak',       'rendah', NULL),
  ('kadang', 'tidak_yakin', 'sedang', NULL),
  ('kadang', 'ya',          'tinggi', NULL),
  ('tidak',  'tidak',       'sedang', 'Cairan pra-ejakulasi tetap berisiko'),
  ('tidak',  'tidak_yakin', 'tinggi', NULL),
  ('tidak',  'ya',          'tinggi', NULL);

INSERT INTO kategori_hasil (kode, skor_min, skor_maks, judul, saran, peringatan) VALUES
  ('belum_bisa_dinilai', NULL, NULL, 'Belum bisa dinilai',
   'Hubungan terakhir belum cukup lama untuk bisa terdeteksi. Lakukan uji paling awal pada tanggal yang tertera, lalu isi ulang kuesioner.',
   'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  ('tanpa_riwayat_hubungan', NULL, NULL, 'Tidak mengarah ke kehamilan',
   'Tanpa riwayat hubungan seksual, keluhan ini lebih mungkin berasal dari gangguan haid seperti stres, perubahan berat badan, atau PCOS. Periksakan ke bidan bila berlanjut.',
   'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  ('rendah',  0,  39, 'Indikasi lemah',
   'Catat siklus haid Anda dan ulangi penilaian 7-10 hari lagi bila haid belum datang.',
   'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  ('sedang', 40,  70, 'Indikasi meragukan',
   'Lakukan test pack dengan urine pagi, hindari obat tanpa resep, dan nilai ulang setelah satu minggu.',
   'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  ('tinggi', 71, 100, 'Indikasi kuat',
   'Lakukan test pack, lalu periksa ke bidan atau dokter untuk tes HCG atau USG dan mulai pemeriksaan kehamilan.',
   'Hasil sistem ini indikasi awal, bukan diagnosis.');


-- =====================================================================
-- PEMBANGKIT 243 ATURAN
--
--   3 himpunan x 4 gejala x 3 tingkat paparan = 3^5 = 243.
--   Tidak ditulis tangan. Caranya dua langkah:
--     1. Jumlahkan bobot 4 gejala (0 sampai 10), lalu tentukan kekuatannya:
--          0-2 = rendah,  3-5 = sedang,  6-10 = tinggi
--        Pembobotan ini dipilih supaya persis cocok dengan 11 pola inti yang
--        disusun bidan secara manual.
--     2. Kesimpulan diambil dari matriks kekuatan gejala x tingkat paparan:
--
--          kekuatan \ paparan | rendah | sedang | tinggi
--          -------------------+--------+--------+-------
--          rendah             | RENDAH | RENDAH | SEDANG
--          sedang             | RENDAH | SEDANG | TINGGI
--          tinggi             | SEDANG | TINGGI | TINGGI
--
--        Matriks ini monoton: menaikkan paparan atau kekuatan gejala tidak
--        pernah menurunkan kesimpulan.
--
--   Setelah ini jalan, bidan boleh mengubah kolom himpunan_hasil_id pada
--   aturan tertentu bila tidak setuju.
-- =====================================================================

INSERT INTO aturan (kode, himpunan_haid_id, himpunan_mual_id, himpunan_nyeri_id,
                    himpunan_bak_id, tingkat_paparan, himpunan_hasil_id,
                    bobot_gejala, kekuatan_gejala)
SELECT  k.kode, k.haid_id, k.mual_id, k.nyeri_id, k.bak_id, k.tingkat_paparan,
        o.id, k.bobot_gejala, k.kekuatan_gejala
FROM (
  SELECT  p.*,
          CASE
            WHEN p.kekuatan_gejala = 'rendah' AND p.tingkat_paparan = 'tinggi' THEN 'SEDANG'
            WHEN p.kekuatan_gejala = 'rendah'                                  THEN 'RENDAH'
            WHEN p.kekuatan_gejala = 'sedang' AND p.tingkat_paparan = 'rendah' THEN 'RENDAH'
            WHEN p.kekuatan_gejala = 'sedang' AND p.tingkat_paparan = 'sedang' THEN 'SEDANG'
            WHEN p.kekuatan_gejala = 'sedang'                                  THEN 'TINGGI'
            WHEN p.kekuatan_gejala = 'tinggi' AND p.tingkat_paparan = 'rendah' THEN 'SEDANG'
            ELSE 'TINGGI'
          END AS kode_hasil
  FROM (
    SELECT  CONCAT_WS('-', h.kode, m.kode, n.kode, b.kode, UPPER(t.tingkat)) AS kode,
            h.id AS haid_id, m.id AS mual_id, n.id AS nyeri_id, b.id AS bak_id,
            t.tingkat AS tingkat_paparan,
            (h.bobot + m.bobot + n.bobot + b.bobot) AS bobot_gejala,
            CASE
              WHEN (h.bobot + m.bobot + n.bobot + b.bobot) <= 2 THEN 'rendah'
              WHEN (h.bobot + m.bobot + n.bobot + b.bobot) <= 5 THEN 'sedang'
              ELSE 'tinggi'
            END AS kekuatan_gejala
    FROM       (SELECT s.* FROM himpunan s JOIN variabel v ON v.id = s.variabel_id WHERE v.kode = 'HAID')  h
    CROSS JOIN (SELECT s.* FROM himpunan s JOIN variabel v ON v.id = s.variabel_id WHERE v.kode = 'MUAL')  m
    CROSS JOIN (SELECT s.* FROM himpunan s JOIN variabel v ON v.id = s.variabel_id WHERE v.kode = 'NYERI') n
    CROSS JOIN (SELECT s.* FROM himpunan s JOIN variabel v ON v.id = s.variabel_id WHERE v.kode = 'BAK')   b
    CROSS JOIN (SELECT 'rendah' AS tingkat UNION ALL SELECT 'sedang' UNION ALL SELECT 'tinggi') t
  ) p
) k
JOIN (SELECT s.* FROM himpunan s JOIN variabel v ON v.id = s.variabel_id WHERE v.kode = 'HASIL') o
     ON o.kode = k.kode_hasil;


-- =====================================================================
-- CONTOH SATU PENILAIAN
--   Jawaban: telat haid 18 hari, mual 6x/hari, nyeri 7, berkemih 11x/hari,
--   hubungan terakhir 20 hari lalu, selalu pakai pengaman, keluar di dalam.
--   Paparan = sedang. Gerbang 7 hari lolos.
--   4 aturan aktif, semuanya alfa = 0,5:
--       SEDANG -> z = 30 + 40*0,5 = 50
--       TINGGI -> z = 60 + 40*0,5 = 80  (tiga aturan)
--   skor = (0,5*50 + 0,5*80 + 0,5*80 + 0,5*80) / 2 = 145 / 2 = 72,5 -> 73
--   Baris contoh ini boleh dihapus sebelum dipakai sungguhan.
-- =====================================================================

INSERT INTO penilaian
  (pengguna_id, telat_haid, mual, nyeri_payudara, berkemih,
   hari_sejak_hubungan, pengaman, keluar_dalam, tingkat_paparan,
   status, skor_mentah, skor, kategori, jumlah_aturan_aktif)
VALUES
  (2, 18, 6, 7, 11, 20, 'selalu', 'ya', 'sedang', 'selesai', 72.5000, 73, 'tinggi', 4);

INSERT INTO penilaian_aturan (penilaian_id, aturan_id, alfa, z)
SELECT LAST_INSERT_ID(), a.id, x.alfa, x.z
FROM   aturan a
JOIN (
            SELECT 'AGAK_TELAT-SEDANG-SEDANG-MENINGKAT-SEDANG' AS kode, 0.5 AS alfa, 50 AS z
  UNION ALL SELECT 'AGAK_TELAT-SEDANG-BERAT-MENINGKAT-SEDANG',        0.5,       80
  UNION ALL SELECT 'AGAK_TELAT-BERAT-SEDANG-MENINGKAT-SEDANG',        0.5,       80
  UNION ALL SELECT 'AGAK_TELAT-BERAT-BERAT-MENINGKAT-SEDANG',         0.5,       80
) x ON x.kode = a.kode;


-- =====================================================================
-- PEMERIKSAAN
--   Jalankan setelah semua di atas. Hasil yang benar ada di komentarnya.
-- =====================================================================

-- Harus 243
-- SELECT COUNT(*) AS jumlah_aturan FROM aturan;

-- Sebaran kesimpulan: Rendah 58, Sedang 81, Tinggi 104
-- SELECT kesimpulan, COUNT(*) FROM v_aturan_terbaca GROUP BY kesimpulan;

-- Sebaran kekuatan gejala: rendah 11 pola, sedang 36 pola, tinggi 34 pola
-- SELECT kekuatan_gejala, COUNT(*) / 3 AS jumlah_pola FROM aturan GROUP BY kekuatan_gejala;

-- Melihat 4 aturan yang aktif pada contoh di atas sebagai kalimat
-- SELECT kalimat FROM v_aturan_terbaca
-- WHERE kode LIKE 'AGAK_TELAT-%-MENINGKAT-SEDANG' AND bobot_gejala >= 5;

-- Harus: skor_dihitung_ulang 72.5, skor_dibulatkan 73, aturan_aktif 4
-- SELECT * FROM v_hitung_ulang;

-- Kolom z_tersimpan dan z_dihitung_ulang harus sama (50, 80, 80, 80)
-- SELECT * FROM v_cek_z;
