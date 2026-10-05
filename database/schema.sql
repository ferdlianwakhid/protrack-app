-- =====================================================================
-- Skema basis data: Sistem Pendukung Keputusan Deteksi Kehamilan Dini
-- Metode: Fuzzy Mamdani, satu basis aturan, 5 anteseden, 243 aturan
--
-- Target  : MySQL 8.0.16+ / MariaDB 10.5+  (CHECK dieksekusi sejak 8.0.16)
-- Charset : utf8mb4
--
-- Prinsip rancangan
--   1. Pengetahuan pakar adalah DATA, bukan kode. Himpunan fuzzy, tabel
--      paparan, basis aturan, ambang kategori, dan teks rekomendasi semua
--      tersimpan di tabel dan bisa diubah bidan tanpa menyentuh program.
--   2. Setiap konfigurasi terikat pada knowledge_version. Hasil penilaian
--      lama tetap bisa direproduksi walau basis aturan sudah direvisi.
--   3. Jejak hitung disimpan penuh (derajat keanggotaan, aturan aktif,
--      alfa-predikat), sehingga satu skor bisa diaudit ulang dengan tangan.
--   4. Aturan bisnis yang bisa dipaksakan di tingkat basis data dijadikan
--      constraint, bukan hanya komentar.
-- =====================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS accuracy_evaluation;
DROP TABLE IF EXISTS clinical_confirmation;
DROP TABLE IF EXISTS assessment_share;
DROP TABLE IF EXISTS assessment_danger_sign;
DROP TABLE IF EXISTS assessment_fired_rule;
DROP TABLE IF EXISTS assessment_membership;
DROP TABLE IF EXISTS assessment_input;
DROP TABLE IF EXISTS assessment;
DROP TABLE IF EXISTS danger_sign;
DROP TABLE IF EXISTS recommendation;
DROP TABLE IF EXISTS score_category;
DROP TABLE IF EXISTS fuzzy_rule_antecedent;
DROP TABLE IF EXISTS fuzzy_rule;
DROP TABLE IF EXISTS consequent_matrix;
DROP TABLE IF EXISTS exposure_matrix;
DROP TABLE IF EXISTS fuzzy_set;
DROP TABLE IF EXISTS fuzzy_variable;
DROP TABLE IF EXISTS knowledge_version;
DROP TABLE IF EXISTS app_user;

SET FOREIGN_KEY_CHECKS = 1;


-- =====================================================================
-- 1. PELAKU
-- =====================================================================

CREATE TABLE app_user (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  full_name       VARCHAR(120)    NOT NULL,
  email           VARCHAR(190)    NOT NULL,
  password_hash   VARCHAR(255)    NOT NULL,
  role            ENUM('pengguna','bidan','admin') NOT NULL DEFAULT 'pengguna',
  birth_date      DATE            NULL,
  phone           VARCHAR(25)     NULL,
  is_active       TINYINT(1)      NOT NULL DEFAULT 1,
  created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_app_user_email (email),
  KEY ix_app_user_role (role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Pengguna, bidan/pakar, dan admin. Hanya bidan/admin boleh mengubah pengetahuan.';


-- =====================================================================
-- 2. VERSI PENGETAHUAN
--    Semua konfigurasi fuzzy menggantung di sini. Satu versi aktif.
-- =====================================================================

CREATE TABLE knowledge_version (
  id              INT UNSIGNED    NOT NULL AUTO_INCREMENT,
  version_no      VARCHAR(20)     NOT NULL COMMENT 'mis. 1.0, 1.1',
  status          ENUM('draf','aktif','arsip') NOT NULL DEFAULT 'draf',
  notes           TEXT            NULL COMMENT 'Alasan revisi, mis. hasil evaluasi akurasi',
  created_by      BIGINT UNSIGNED NOT NULL,
  activated_at    DATETIME        NULL,
  archived_at     DATETIME        NULL,
  created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_knowledge_version_no (version_no),
  KEY ix_knowledge_version_status (status),
  CONSTRAINT fk_kv_creator FOREIGN KEY (created_by) REFERENCES app_user (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Versi pengetahuan pakar. Penilaian menyimpan versi yang dipakainya.';


-- =====================================================================
-- 3. VARIABEL DAN HIMPUNAN FUZZY
-- =====================================================================

CREATE TABLE fuzzy_variable (
  id                  INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  knowledge_version_id INT UNSIGNED NOT NULL,
  code                VARCHAR(40)   NOT NULL COMMENT 'TELAT_HAID, MUAL, NYERI, BERKEMIH, PAPARAN, KEMUNGKINAN_HAMIL',
  name                VARCHAR(120)  NOT NULL,
  unit                VARCHAR(40)   NULL COMMENT 'hari, kali/hari, skala 0-10, skor',
  role                ENUM('anteseden','konsekuen') NOT NULL,
  value_type          ENUM('fuzzy','tegas') NOT NULL DEFAULT 'fuzzy'
                        COMMENT 'tegas = jawaban kategorik, masuk aturan dengan mu = 1',
  domain_min          DECIMAL(8,2)  NULL,
  domain_max          DECIMAL(8,2)  NULL,
  sort_order          TINYINT UNSIGNED NOT NULL COMMENT 'urutan anteseden pada rule_code',
  is_active           TINYINT(1)    NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY uq_var_code (knowledge_version_id, code),
  UNIQUE KEY uq_var_order (knowledge_version_id, role, sort_order),
  CONSTRAINT fk_var_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id),
  CONSTRAINT ck_var_domain CHECK (domain_min IS NULL OR domain_max IS NULL OR domain_min < domain_max)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='5 anteseden + 1 konsekuen. Jarak hubungan TIDAK ada di sini: dia gerbang, bukan anteseden.';

CREATE TABLE fuzzy_set (
  id              INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  variable_id     INT UNSIGNED  NOT NULL,
  code            VARCHAR(40)   NOT NULL COMMENT 'TEPAT_WAKTU, AGAK_TELAT, TELAT, RINGAN, ...',
  name            VARCHAR(80)   NOT NULL,
  shape           ENUM('trapesium','triangular','singleton','tegas') NOT NULL DEFAULT 'trapesium',
  -- Titik trapesium: mu=0 sebelum a, naik a->b, mu=1 b->c, turun c->d, mu=0 setelah d.
  -- Triangular dipakai dengan b = c. Singleton/tegas memakai z dan mengosongkan a..d.
  a               DECIMAL(8,2)  NULL,
  b               DECIMAL(8,2)  NULL,
  c               DECIMAL(8,2)  NULL,
  d               DECIMAL(8,2)  NULL,
  z               DECIMAL(8,2)  NULL COMMENT 'Nilai wakil konsekuen untuk defuzzifikasi rata-rata terbobot',
  weight          TINYINT UNSIGNED NULL
                    COMMENT 'Bobot gejala untuk MENYUSUN basis aturan. Tidak dipakai saat inferensi.',
  sort_order      TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_set_code (variable_id, code),
  KEY ix_set_variable (variable_id, sort_order),
  CONSTRAINT fk_set_variable FOREIGN KEY (variable_id) REFERENCES fuzzy_variable (id) ON DELETE CASCADE,
  CONSTRAINT ck_set_trapezoid CHECK (
    a IS NULL OR (a <= b AND b <= c AND c <= d)
  )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Himpunan fuzzy tiap variabel. 3 himpunan per variabel pada versi 1.0.';


-- =====================================================================
-- 4. PRA-PEMROSESAN: TABEL PAPARAN 3 x 3
--    9 kombinasi jawaban -> 3 tingkat. Tegas, bukan fuzzy, karena jawaban
--    ya/tidak tidak punya derajat keanggotaan.
-- =====================================================================

CREATE TABLE exposure_matrix (
  id                    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  knowledge_version_id  INT UNSIGNED NOT NULL,
  contraceptive_use     ENUM('selalu','kadang','tidak') NOT NULL,
  internal_ejaculation  ENUM('tidak','tidak_yakin','ya') NOT NULL,
  exposure_level        ENUM('rendah','sedang','tinggi') NOT NULL,
  note                  VARCHAR(190) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_exposure_cell (knowledge_version_id, contraceptive_use, internal_ejaculation),
  CONSTRAINT fk_exposure_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Aturan bisnis: ejakulasi di dalam tidak pernah menghasilkan paparan rendah.';


-- =====================================================================
-- 5. MATRIKS KONSEKUEN
--    Dipakai SEKALI untuk menurunkan 243 konsekuen. Bukan tahap inferensi.
-- =====================================================================

CREATE TABLE consequent_matrix (
  id                    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  knowledge_version_id  INT UNSIGNED NOT NULL,
  symptom_strength      ENUM('rendah','sedang','tinggi') NOT NULL,
  exposure_level        ENUM('rendah','sedang','tinggi') NOT NULL,
  consequent_code       VARCHAR(40)  NOT NULL COMMENT 'kode himpunan pada variabel KEMUNGKINAN_HAMIL',
  PRIMARY KEY (id),
  UNIQUE KEY uq_consequent_cell (knowledge_version_id, symptom_strength, exposure_level),
  CONSTRAINT fk_cmatrix_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Harus monoton: menaikkan paparan atau kekuatan gejala tidak boleh menurunkan konsekuen.';


-- =====================================================================
-- 6. BASIS ATURAN
--    rule_code adalah tanda tangan aturan: kode himpunan tiap anteseden
--    dirangkai menurut fuzzy_variable.sort_order. UNIQUE pada kolom ini
--    yang mencegah aturan kembar atau bertentangan.
-- =====================================================================

CREATE TABLE fuzzy_rule (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  knowledge_version_id  INT UNSIGNED    NOT NULL,
  rule_code             VARCHAR(96)     NOT NULL,
  consequent_set_id     INT UNSIGNED    NOT NULL,
  origin                ENUM('generated','pakar') NOT NULL DEFAULT 'generated'
                          COMMENT 'pakar = konsekuen di-override manual oleh bidan',
  symptom_weight        TINYINT UNSIGNED NULL COMMENT 'Jumlah bobot gejala, untuk pemeriksaan monotonisitas',
  symptom_strength      ENUM('rendah','sedang','tinggi') NULL,
  is_active             TINYINT(1)      NOT NULL DEFAULT 1,
  updated_by            BIGINT UNSIGNED NULL,
  updated_at            DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_rule_signature (knowledge_version_id, rule_code),
  KEY ix_rule_consequent (consequent_set_id),
  CONSTRAINT fk_rule_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id),
  CONSTRAINT fk_rule_consequent FOREIGN KEY (consequent_set_id) REFERENCES fuzzy_set (id),
  CONSTRAINT fk_rule_editor FOREIGN KEY (updated_by) REFERENCES app_user (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='243 aturan pada versi 1.0 (3^5).';

CREATE TABLE fuzzy_rule_antecedent (
  fuzzy_rule_id   BIGINT UNSIGNED NOT NULL,
  variable_id     INT UNSIGNED    NOT NULL,
  fuzzy_set_id    INT UNSIGNED    NOT NULL,
  PRIMARY KEY (fuzzy_rule_id, variable_id),
  KEY ix_ante_set (fuzzy_set_id),
  CONSTRAINT fk_ante_rule FOREIGN KEY (fuzzy_rule_id) REFERENCES fuzzy_rule (id) ON DELETE CASCADE,
  CONSTRAINT fk_ante_variable FOREIGN KEY (variable_id) REFERENCES fuzzy_variable (id),
  CONSTRAINT fk_ante_set FOREIGN KEY (fuzzy_set_id) REFERENCES fuzzy_set (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Satu baris per anteseden. PK (aturan, variabel) menjamin satu variabel sekali per aturan.';


-- =====================================================================
-- 7. AMBANG KATEGORI DAN TEKS REKOMENDASI
-- =====================================================================

CREATE TABLE score_category (
  id                    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  knowledge_version_id  INT UNSIGNED NOT NULL,
  category              ENUM('rendah','sedang','tinggi') NOT NULL,
  score_min             TINYINT UNSIGNED NOT NULL,
  score_max             TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_category (knowledge_version_id, category),
  CONSTRAINT fk_category_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id),
  CONSTRAINT ck_category_range CHECK (score_min <= score_max AND score_max <= 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Ambang pengelompokan skor yang sudah dibulatkan.';

CREATE TABLE recommendation (
  id                    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  knowledge_version_id  INT UNSIGNED NOT NULL,
  outcome               ENUM('belum_bisa_dinilai','tanpa_riwayat_hubungan','rujukan_darurat',
                             'rendah','sedang','tinggi') NOT NULL,
  title                 VARCHAR(120) NOT NULL,
  body                  TEXT         NOT NULL,
  disclaimer            TEXT         NOT NULL COMMENT 'Wajib tampil: hasil bukan diagnosis',
  PRIMARY KEY (id),
  UNIQUE KEY uq_reco_outcome (knowledge_version_id, outcome),
  CONSTRAINT fk_reco_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE danger_sign (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  code        VARCHAR(40)  NOT NULL,
  name        VARCHAR(120) NOT NULL,
  is_active   TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY uq_danger_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Gejala bahaya. Satu saja ditandai, alur dipotong dan skor tidak dihitung.';


-- =====================================================================
-- 8. PENILAIAN
-- =====================================================================

CREATE TABLE assessment (
  id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  app_user_id             BIGINT UNSIGNED NOT NULL,
  knowledge_version_id    INT UNSIGNED    NOT NULL,
  submitted_at            DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- Riwayat paparan (3 jawaban)
  never_had_intercourse   TINYINT(1)      NOT NULL DEFAULT 0,
  last_intercourse_date   DATE            NULL,
  days_since_intercourse  SMALLINT UNSIGNED NULL,
  contraceptive_use       ENUM('selalu','kadang','tidak','tidak_dijawab') NOT NULL DEFAULT 'tidak_dijawab',
  internal_ejaculation    ENUM('tidak','tidak_yakin','ya','tidak_dijawab') NOT NULL DEFAULT 'tidak_dijawab',
  exposure_level          ENUM('rendah','sedang','tinggi') NULL COMMENT 'Hasil exposure_matrix',
  based_on_assumption     TINYINT(1)      NOT NULL DEFAULT 0
                            COMMENT 'Pertanyaan paparan dilewati, dipakai asumsi paparan tertinggi',

  -- Gerbang waktu
  gate_status             ENUM('lolos','belum_bisa_dinilai','tanpa_riwayat_hubungan','rujukan_darurat') NOT NULL,
  gate_reason             VARCHAR(190)    NULL,
  earliest_test_date      DATE            NULL COMMENT 'tanggal hubungan + 14 hari',

  -- Hasil inferensi
  raw_score               DECIMAL(7,4)    NULL COMMENT 'Hasil defuzzifikasi sebelum pembulatan',
  score                   TINYINT UNSIGNED NULL COMMENT 'Skor akhir yang dibulatkan',
  category                ENUM('rendah','sedang','tinggi') NULL,
  recommendation_id       INT UNSIGNED    NULL,
  fired_rule_count        SMALLINT UNSIGNED NULL,

  created_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_assessment_user (app_user_id, submitted_at),
  KEY ix_assessment_version (knowledge_version_id),
  KEY ix_assessment_category (category),
  CONSTRAINT fk_assessment_user FOREIGN KEY (app_user_id) REFERENCES app_user (id),
  CONSTRAINT fk_assessment_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id),
  CONSTRAINT fk_assessment_reco FOREIGN KEY (recommendation_id) REFERENCES recommendation (id),
  -- Gerbang gagal berarti TIDAK ADA skor. Ini aturan bisnis nomor 2 dan 8,
  -- dipaksakan di tingkat basis data supaya tidak bisa dilanggar aplikasi.
  CONSTRAINT ck_assessment_gate CHECK (
    (gate_status = 'lolos'  AND score IS NOT NULL AND category IS NOT NULL)
    OR
    (gate_status <> 'lolos' AND score IS NULL     AND category IS NULL)
  ),
  CONSTRAINT ck_assessment_score CHECK (score IS NULL OR score <= 100),
  CONSTRAINT ck_assessment_never CHECK (
    never_had_intercourse = 0 OR gate_status = 'tanpa_riwayat_hubungan'
  )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Satu baris per pengisian kuesioner.';

CREATE TABLE assessment_input (
  assessment_id   BIGINT UNSIGNED NOT NULL,
  variable_id     INT UNSIGNED    NOT NULL,
  crisp_value     DECIMAL(8,2)    NOT NULL,
  PRIMARY KEY (assessment_id, variable_id),
  CONSTRAINT fk_input_assessment FOREIGN KEY (assessment_id) REFERENCES assessment (id) ON DELETE CASCADE,
  CONSTRAINT fk_input_variable FOREIGN KEY (variable_id) REFERENCES fuzzy_variable (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Nilai crisp 4 gejala. Normalisasi ini membuat penambahan variabel tidak mengubah struktur tabel.';

CREATE TABLE assessment_membership (
  assessment_id   BIGINT UNSIGNED NOT NULL,
  fuzzy_set_id    INT UNSIGNED    NOT NULL,
  mu              DECIMAL(5,4)    NOT NULL,
  PRIMARY KEY (assessment_id, fuzzy_set_id),
  CONSTRAINT fk_mu_assessment FOREIGN KEY (assessment_id) REFERENCES assessment (id) ON DELETE CASCADE,
  CONSTRAINT fk_mu_set FOREIGN KEY (fuzzy_set_id) REFERENCES fuzzy_set (id),
  CONSTRAINT ck_mu_range CHECK (mu >= 0 AND mu <= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Tahap 2 fuzzifikasi. Simpan hanya mu > 0 agar tabel tetap ringan.';

CREATE TABLE assessment_fired_rule (
  assessment_id       BIGINT UNSIGNED NOT NULL,
  fuzzy_rule_id       BIGINT UNSIGNED NOT NULL,
  alpha               DECIMAL(5,4)    NOT NULL COMMENT 'alfa-predikat = MIN seluruh anteseden',
  consequent_set_id   INT UNSIGNED    NOT NULL,
  z                   DECIMAL(8,2)    NOT NULL COMMENT 'Salinan nilai z saat penilaian dijalankan',
  PRIMARY KEY (assessment_id, fuzzy_rule_id),
  CONSTRAINT fk_fired_assessment FOREIGN KEY (assessment_id) REFERENCES assessment (id) ON DELETE CASCADE,
  CONSTRAINT fk_fired_rule FOREIGN KEY (fuzzy_rule_id) REFERENCES fuzzy_rule (id),
  CONSTRAINT fk_fired_consequent FOREIGN KEY (consequent_set_id) REFERENCES fuzzy_set (id),
  CONSTRAINT ck_alpha_range CHECK (alpha > 0 AND alpha <= 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Tahap 3-5. Dari tabel ini skor bisa dihitung ulang: SUM(alpha*z)/SUM(alpha).';

CREATE TABLE assessment_danger_sign (
  assessment_id   BIGINT UNSIGNED NOT NULL,
  danger_sign_id  INT UNSIGNED    NOT NULL,
  PRIMARY KEY (assessment_id, danger_sign_id),
  CONSTRAINT fk_ads_assessment FOREIGN KEY (assessment_id) REFERENCES assessment (id) ON DELETE CASCADE,
  CONSTRAINT fk_ads_sign FOREIGN KEY (danger_sign_id) REFERENCES danger_sign (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 9. PRIVASI: BERBAGI HASIL KE BIDAN
--    Aturan bisnis 10: data paparan hanya ikut terkirim bila disetujui.
-- =====================================================================

CREATE TABLE assessment_share (
  id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  assessment_id           BIGINT UNSIGNED NOT NULL,
  shared_with_user_id     BIGINT UNSIGNED NOT NULL,
  include_exposure_data   TINYINT(1)      NOT NULL DEFAULT 0
                            COMMENT 'Hanya 1 bila pengguna menyetujui secara eksplisit',
  consented_at            DATETIME        NOT NULL,
  revoked_at              DATETIME        NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_share (assessment_id, shared_with_user_id),
  CONSTRAINT fk_share_assessment FOREIGN KEY (assessment_id) REFERENCES assessment (id) ON DELETE CASCADE,
  CONSTRAINT fk_share_user FOREIGN KEY (shared_with_user_id) REFERENCES app_user (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 10. KONFIRMASI KLINIS DAN EVALUASI AKURASI
-- =====================================================================

CREATE TABLE clinical_confirmation (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  assessment_id   BIGINT UNSIGNED NOT NULL,
  confirmed_by    BIGINT UNSIGNED NOT NULL COMMENT 'app_user dengan role bidan',
  method          ENUM('test_pack','hcg','usg','pemeriksaan_klinis') NOT NULL,
  result          ENUM('hamil','tidak_hamil','belum_pasti') NOT NULL,
  confirmed_at    DATETIME        NOT NULL,
  notes           TEXT            NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_confirmation (assessment_id, method),
  KEY ix_confirmation_result (result),
  CONSTRAINT fk_conf_assessment FOREIGN KEY (assessment_id) REFERENCES assessment (id),
  CONSTRAINT fk_conf_user FOREIGN KEY (confirmed_by) REFERENCES app_user (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Kebenaran lapangan untuk mengukur akurasi sistem.';

CREATE TABLE accuracy_evaluation (
  id                      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  knowledge_version_id    INT UNSIGNED    NOT NULL,
  period_start            DATE            NOT NULL,
  period_end              DATE            NOT NULL,
  case_count              SMALLINT UNSIGNED NOT NULL COMMENT 'Dievaluasi setiap 50 kasus terkonfirmasi',
  true_positive           SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  true_negative           SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  false_positive          SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  false_negative          SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  accuracy                DECIMAL(5,2)    NULL COMMENT 'persen',
  sensitivity             DECIMAL(5,2)    NULL,
  specificity             DECIMAL(5,2)    NULL,
  conclusion              TEXT            NULL,
  evaluated_by            BIGINT UNSIGNED NOT NULL,
  created_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_eval_version (knowledge_version_id),
  CONSTRAINT fk_eval_version FOREIGN KEY (knowledge_version_id) REFERENCES knowledge_version (id),
  CONSTRAINT fk_eval_user FOREIGN KEY (evaluated_by) REFERENCES app_user (id),
  CONSTRAINT ck_eval_period CHECK (period_start <= period_end)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE audit_log (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  app_user_id     BIGINT UNSIGNED NOT NULL,
  entity          VARCHAR(60)     NOT NULL COMMENT 'fuzzy_set, fuzzy_rule, exposure_matrix, ...',
  entity_id       BIGINT UNSIGNED NULL,
  action          ENUM('create','update','delete','activate','archive') NOT NULL,
  before_value    JSON            NULL,
  after_value     JSON            NULL,
  created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_audit_entity (entity, entity_id),
  KEY ix_audit_user (app_user_id, created_at),
  CONSTRAINT fk_audit_user FOREIGN KEY (app_user_id) REFERENCES app_user (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Aturan bisnis 9: setiap perubahan pengetahuan tercatat beserta pengubahnya.';


-- =====================================================================
-- 11. VIEW BANTU
-- =====================================================================

CREATE OR REPLACE VIEW v_rule_readable AS
SELECT  r.id,
        r.rule_code,
        GROUP_CONCAT(CONCAT(v.name, ' = ', s.name)
                     ORDER BY v.sort_order SEPARATOR ' AND ')      AS antecedents,
        o.name                                                     AS consequent,
        o.z                                                        AS consequent_z,
        r.symptom_weight,
        r.symptom_strength,
        r.origin
FROM        fuzzy_rule            r
JOIN        fuzzy_rule_antecedent ra ON ra.fuzzy_rule_id = r.id
JOIN        fuzzy_set             s  ON s.id  = ra.fuzzy_set_id
JOIN        fuzzy_variable        v  ON v.id  = ra.variable_id
JOIN        fuzzy_set             o  ON o.id  = r.consequent_set_id
WHERE       r.is_active = 1
GROUP BY    r.id, r.rule_code, o.name, o.z, r.symptom_weight, r.symptom_strength, r.origin;

CREATE OR REPLACE VIEW v_assessment_recompute AS
SELECT  a.id                                           AS assessment_id,
        a.score                                         AS stored_score,
        ROUND(SUM(f.alpha * f.z) / SUM(f.alpha))        AS recomputed_score,
        SUM(f.alpha * f.z)                              AS numerator,
        SUM(f.alpha)                                    AS denominator,
        COUNT(*)                                        AS fired_rules
FROM        assessment            a
JOIN        assessment_fired_rule f ON f.assessment_id = a.id
GROUP BY    a.id, a.score;


-- =====================================================================
-- 12. SEED: KONFIGURASI VERSI 1.0
-- =====================================================================

INSERT INTO app_user (full_name, email, password_hash, role) VALUES
  ('Administrator', 'admin@example.test', '$2y$10$ganti.dengan.hash.asli.saat.instalasi', 'admin'),
  ('Bidan Pembina',  'bidan@example.test', '$2y$10$ganti.dengan.hash.asli.saat.instalasi', 'bidan');

INSERT INTO knowledge_version (version_no, status, notes, created_by, activated_at) VALUES
  ('1.0', 'aktif', 'Konfigurasi awal: 5 anteseden, 243 aturan.', 1, NOW());

INSERT INTO fuzzy_variable
  (knowledge_version_id, code, name, unit, role, value_type, domain_min, domain_max, sort_order) VALUES
  (1, 'TELAT_HAID',        'Keterlambatan haid',        'hari',        'anteseden', 'fuzzy',   0,  60, 1),
  (1, 'MUAL',              'Mual dan muntah',           'kali/hari',   'anteseden', 'fuzzy',   0,  10, 2),
  (1, 'NYERI',             'Nyeri dan sensitif payudara','skala 0-10', 'anteseden', 'fuzzy',   0,  10, 3),
  (1, 'BERKEMIH',          'Frekuensi berkemih',        'kali/hari',   'anteseden', 'fuzzy',   4,  20, 4),
  (1, 'PAPARAN',           'Tingkat paparan',           NULL,          'anteseden', 'tegas', NULL, NULL, 5),
  (1, 'KEMUNGKINAN_HAMIL', 'Kemungkinan hamil',         'skor',        'konsekuen', 'fuzzy',   0, 100, 1);

INSERT INTO fuzzy_set (variable_id, code, name, shape, a, b, c, d, z, weight, sort_order)
SELECT v.id, x.code, x.name, x.shape, x.a, x.b, x.c, x.d, x.z, x.weight, x.sort_order
FROM fuzzy_variable v
JOIN (
  -- Keterlambatan haid: bobot 0 / 2 / 4. Amenorrhea diberi bobot ganda karena
  -- satu-satunya gejala yang bisa berdiri sendiri sebagai indikasi.
  SELECT 'TELAT_HAID' AS vcode, 'TEPAT_WAKTU' AS code, 'Tepat waktu' AS name, 'trapesium' AS shape,
          0 AS a,  0 AS b,  5 AS c, 12 AS d, NULL AS z, 0 AS weight, 1 AS sort_order
  UNION ALL SELECT 'TELAT_HAID','AGAK_TELAT','Agak telat','trapesium',  7, 14, 21, 28, NULL, 2, 2
  UNION ALL SELECT 'TELAT_HAID','TELAT','Telat','trapesium',           21, 35, 60, 60, NULL, 4, 3
  UNION ALL SELECT 'MUAL','RINGAN','Ringan','trapesium',                0,  0,  1,  3, NULL, 0, 1
  UNION ALL SELECT 'MUAL','SEDANG','Sedang','trapesium',                2,  4,  5,  7, NULL, 1, 2
  UNION ALL SELECT 'MUAL','BERAT','Berat','trapesium',                  5,  7, 10, 10, NULL, 2, 3
  UNION ALL SELECT 'NYERI','RINGAN','Ringan','trapesium',               0,  0,  2,  5, NULL, 0, 1
  UNION ALL SELECT 'NYERI','SEDANG','Sedang','trapesium',               3,  5,  6,  8, NULL, 1, 2
  UNION ALL SELECT 'NYERI','BERAT','Berat','trapesium',                 6,  8, 10, 10, NULL, 2, 3
  UNION ALL SELECT 'BERKEMIH','NORMAL','Normal','trapesium',            4,  4,  6,  9, NULL, 0, 1
  UNION ALL SELECT 'BERKEMIH','MENINGKAT','Meningkat','trapesium',      7, 10, 12, 15, NULL, 1, 2
  UNION ALL SELECT 'BERKEMIH','SERING','Sering','trapesium',           12, 15, 20, 20, NULL, 2, 3
  UNION ALL SELECT 'PAPARAN','RENDAH','Rendah','tegas',              NULL,NULL,NULL,NULL,NULL,NULL,1
  UNION ALL SELECT 'PAPARAN','SEDANG','Sedang','tegas',              NULL,NULL,NULL,NULL,NULL,NULL,2
  UNION ALL SELECT 'PAPARAN','TINGGI','Tinggi','tegas',              NULL,NULL,NULL,NULL,NULL,NULL,3
  UNION ALL SELECT 'KEMUNGKINAN_HAMIL','RENDAH','Rendah','singleton',NULL,NULL,NULL,NULL,  20,NULL,1
  UNION ALL SELECT 'KEMUNGKINAN_HAMIL','SEDANG','Sedang','singleton',NULL,NULL,NULL,NULL,  50,NULL,2
  UNION ALL SELECT 'KEMUNGKINAN_HAMIL','TINGGI','Tinggi','singleton',NULL,NULL,NULL,NULL,  85,NULL,3
) AS x ON x.vcode = v.code
WHERE v.knowledge_version_id = 1;

INSERT INTO exposure_matrix
  (knowledge_version_id, contraceptive_use, internal_ejaculation, exposure_level, note) VALUES
  (1, 'selalu', 'tidak',       'rendah', NULL),
  (1, 'selalu', 'tidak_yakin', 'rendah', NULL),
  (1, 'selalu', 'ya',          'sedang', 'Kontrasepsi punya angka kegagalan, tidak pernah rendah'),
  (1, 'kadang', 'tidak',       'rendah', NULL),
  (1, 'kadang', 'tidak_yakin', 'sedang', NULL),
  (1, 'kadang', 'ya',          'tinggi', NULL),
  (1, 'tidak',  'tidak',       'sedang', 'Cairan pra-ejakulasi tetap berisiko'),
  (1, 'tidak',  'tidak_yakin', 'tinggi', NULL),
  (1, 'tidak',  'ya',          'tinggi', NULL);

INSERT INTO consequent_matrix
  (knowledge_version_id, symptom_strength, exposure_level, consequent_code) VALUES
  (1, 'rendah', 'rendah', 'RENDAH'),
  (1, 'rendah', 'sedang', 'RENDAH'),
  (1, 'rendah', 'tinggi', 'SEDANG'),
  (1, 'sedang', 'rendah', 'RENDAH'),
  (1, 'sedang', 'sedang', 'SEDANG'),
  (1, 'sedang', 'tinggi', 'TINGGI'),
  (1, 'tinggi', 'rendah', 'SEDANG'),
  (1, 'tinggi', 'sedang', 'TINGGI'),
  (1, 'tinggi', 'tinggi', 'TINGGI');

INSERT INTO score_category (knowledge_version_id, category, score_min, score_max) VALUES
  (1, 'rendah',  0,  39),
  (1, 'sedang', 40,  70),
  (1, 'tinggi', 71, 100);

INSERT INTO danger_sign (code, name) VALUES
  ('PERDARAHAN',   'Perdarahan dari jalan lahir'),
  ('NYERI_HEBAT',  'Nyeri perut bagian bawah yang hebat'),
  ('PINGSAN',      'Pingsan atau hampir pingsan'),
  ('DEMAM_TINGGI', 'Demam tinggi disertai nyeri perut');

INSERT INTO recommendation (knowledge_version_id, outcome, title, body, disclaimer) VALUES
  (1, 'belum_bisa_dinilai', 'Belum bisa dinilai',
      'Hubungan terakhir belum cukup lama untuk bisa terdeteksi. Lakukan uji paling awal pada tanggal yang tertera, lalu isi ulang kuesioner.',
      'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  (1, 'tanpa_riwayat_hubungan', 'Tidak mengarah ke kehamilan',
      'Tanpa riwayat hubungan seksual, keluhan ini lebih mungkin berasal dari gangguan haid, misalnya stres, perubahan berat badan, atau PCOS. Periksakan ke bidan bila berlanjut.',
      'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  (1, 'rujukan_darurat', 'Segera periksa ke fasilitas kesehatan',
      'Anda menandai gejala yang perlu penanganan segera. Jangan menunggu hasil penilaian; periksakan diri sekarang.',
      'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  (1, 'rendah', 'Indikasi lemah',
      'Catat siklus haid Anda dan ulangi penilaian 7-10 hari lagi bila haid belum datang.',
      'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  (1, 'sedang', 'Indikasi meragukan',
      'Lakukan test pack dengan urine pagi, hindari obat tanpa resep, dan nilai ulang setelah satu minggu.',
      'Hasil sistem ini indikasi awal, bukan diagnosis.'),
  (1, 'tinggi', 'Indikasi kuat',
      'Lakukan test pack, lalu periksa ke bidan atau dokter untuk tes HCG atau USG dan mulai pemeriksaan kehamilan.',
      'Hasil sistem ini indikasi awal, bukan diagnosis.');


-- =====================================================================
-- 13. GENERATOR 243 ATURAN
--
--   Basis aturan tidak ditulis tangan satu per satu. Kekuatan gejala tiap
--   pola diturunkan dari jumlah bobot himpunan (0-10):
--        <= 2  -> rendah      3-5 -> sedang      >= 6 -> tinggi
--   Pembobotan ini dipilih supaya persis mereproduksi 11 pola inti yang
--   disusun bidan. Konsekuen lalu diambil dari consequent_matrix.
--
--   Setelah generator jalan, bidan boleh meng-override konsekuen aturan
--   tertentu; set origin = 'pakar' agar perubahan itu tidak tertimpa saat
--   generator dijalankan ulang untuk versi berikutnya.
-- =====================================================================

DROP TABLE IF EXISTS seed_rule_combination;
CREATE TABLE seed_rule_combination (
  rule_code         VARCHAR(96)  NOT NULL PRIMARY KEY,
  set_haid_id       INT UNSIGNED NOT NULL,
  set_mual_id       INT UNSIGNED NOT NULL,
  set_nyeri_id      INT UNSIGNED NOT NULL,
  set_berkemih_id   INT UNSIGNED NOT NULL,
  set_paparan_id    INT UNSIGNED NOT NULL,
  symptom_weight    TINYINT UNSIGNED NOT NULL,
  symptom_strength  ENUM('rendah','sedang','tinggi') NOT NULL,
  consequent_set_id INT UNSIGNED NOT NULL
) ENGINE=InnoDB;

INSERT INTO seed_rule_combination
SELECT  k.rule_code, k.set_haid_id, k.set_mual_id, k.set_nyeri_id,
        k.set_berkemih_id, k.set_paparan_id, k.symptom_weight,
        k.symptom_strength, o.id
FROM (
  SELECT  CONCAT_WS('-', h.code, m.code, n.code, b.code, p.code)      AS rule_code,
          h.id AS set_haid_id, m.id AS set_mual_id, n.id AS set_nyeri_id,
          b.id AS set_berkemih_id, p.id AS set_paparan_id,
          LOWER(p.code)                                               AS exposure_level,
          (h.weight + m.weight + n.weight + b.weight)                 AS symptom_weight,
          CASE
            WHEN (h.weight + m.weight + n.weight + b.weight) <= 2 THEN 'rendah'
            WHEN (h.weight + m.weight + n.weight + b.weight) <= 5 THEN 'sedang'
            ELSE 'tinggi'
          END                                                         AS symptom_strength
  FROM      (SELECT s.* FROM fuzzy_set s JOIN fuzzy_variable v ON v.id = s.variable_id
             WHERE v.knowledge_version_id = 1 AND v.code = 'TELAT_HAID') h
  CROSS JOIN (SELECT s.* FROM fuzzy_set s JOIN fuzzy_variable v ON v.id = s.variable_id
             WHERE v.knowledge_version_id = 1 AND v.code = 'MUAL') m
  CROSS JOIN (SELECT s.* FROM fuzzy_set s JOIN fuzzy_variable v ON v.id = s.variable_id
             WHERE v.knowledge_version_id = 1 AND v.code = 'NYERI') n
  CROSS JOIN (SELECT s.* FROM fuzzy_set s JOIN fuzzy_variable v ON v.id = s.variable_id
             WHERE v.knowledge_version_id = 1 AND v.code = 'BERKEMIH') b
  CROSS JOIN (SELECT s.* FROM fuzzy_set s JOIN fuzzy_variable v ON v.id = s.variable_id
             WHERE v.knowledge_version_id = 1 AND v.code = 'PAPARAN') p
) k
JOIN consequent_matrix cm
     ON cm.knowledge_version_id = 1
    AND cm.symptom_strength     = k.symptom_strength
    AND cm.exposure_level       = k.exposure_level
JOIN (SELECT s.* FROM fuzzy_set s JOIN fuzzy_variable v ON v.id = s.variable_id
      WHERE v.knowledge_version_id = 1 AND v.code = 'KEMUNGKINAN_HAMIL') o
     ON o.code = cm.consequent_code;

INSERT INTO fuzzy_rule
  (knowledge_version_id, rule_code, consequent_set_id, origin, symptom_weight, symptom_strength, updated_by)
SELECT 1, rule_code, consequent_set_id, 'generated', symptom_weight, symptom_strength, 2
FROM   seed_rule_combination;

INSERT INTO fuzzy_rule_antecedent (fuzzy_rule_id, variable_id, fuzzy_set_id)
SELECT r.id, s.variable_id, s.id
FROM   fuzzy_rule r
JOIN   seed_rule_combination c ON c.rule_code = r.rule_code
JOIN   fuzzy_set s             ON s.id        = c.set_haid_id
WHERE  r.knowledge_version_id = 1;

INSERT INTO fuzzy_rule_antecedent (fuzzy_rule_id, variable_id, fuzzy_set_id)
SELECT r.id, s.variable_id, s.id
FROM   fuzzy_rule r
JOIN   seed_rule_combination c ON c.rule_code = r.rule_code
JOIN   fuzzy_set s             ON s.id        = c.set_mual_id
WHERE  r.knowledge_version_id = 1;

INSERT INTO fuzzy_rule_antecedent (fuzzy_rule_id, variable_id, fuzzy_set_id)
SELECT r.id, s.variable_id, s.id
FROM   fuzzy_rule r
JOIN   seed_rule_combination c ON c.rule_code = r.rule_code
JOIN   fuzzy_set s             ON s.id        = c.set_nyeri_id
WHERE  r.knowledge_version_id = 1;

INSERT INTO fuzzy_rule_antecedent (fuzzy_rule_id, variable_id, fuzzy_set_id)
SELECT r.id, s.variable_id, s.id
FROM   fuzzy_rule r
JOIN   seed_rule_combination c ON c.rule_code = r.rule_code
JOIN   fuzzy_set s             ON s.id        = c.set_berkemih_id
WHERE  r.knowledge_version_id = 1;

INSERT INTO fuzzy_rule_antecedent (fuzzy_rule_id, variable_id, fuzzy_set_id)
SELECT r.id, s.variable_id, s.id
FROM   fuzzy_rule r
JOIN   seed_rule_combination c ON c.rule_code = r.rule_code
JOIN   fuzzy_set s             ON s.id        = c.set_paparan_id
WHERE  r.knowledge_version_id = 1;

DROP TABLE seed_rule_combination;


-- =====================================================================
-- 14. PEMERIKSAAN HASIL SEED
--     Jalankan setelah skrip di atas. Hasil yang diharapkan ada di komentar.
-- =====================================================================

-- Harus 243
-- SELECT COUNT(*) AS jumlah_aturan FROM fuzzy_rule WHERE knowledge_version_id = 1;

-- Harus 1215 (243 x 5 anteseden)
-- SELECT COUNT(*) AS jumlah_anteseden FROM fuzzy_rule_antecedent;

-- Sebaran konsekuen: Rendah 58, Sedang 81, Tinggi 104
-- SELECT o.name, COUNT(*) FROM fuzzy_rule r JOIN fuzzy_set o ON o.id = r.consequent_set_id
-- GROUP BY o.name ORDER BY o.sort_order;

-- Sebaran kekuatan gejala: rendah 11 pola, sedang 36 pola, tinggi 34 pola (total 81)
-- SELECT symptom_strength, COUNT(*) / 3 AS jumlah_pola FROM fuzzy_rule
-- WHERE knowledge_version_id = 1 GROUP BY symptom_strength;

-- Pola P5 pada tiap tingkat paparan: Rendah, Sedang, Tinggi
-- SELECT rule_code, consequent FROM v_rule_readable
-- WHERE rule_code LIKE 'AGAK_TELAT-SEDANG-SEDANG-MENINGKAT-%';

-- Aturan yang aktif pada contoh kasus di dokumen probis
-- (telat 18 hari, mual 6x, nyeri 7, berkemih 11x, paparan Sedang):
-- SELECT rule_code, consequent, consequent_z FROM v_rule_readable WHERE rule_code IN (
--   'AGAK_TELAT-SEDANG-SEDANG-MENINGKAT-SEDANG',
--   'AGAK_TELAT-SEDANG-BERAT-MENINGKAT-SEDANG',
--   'AGAK_TELAT-BERAT-SEDANG-MENINGKAT-SEDANG',
--   'AGAK_TELAT-BERAT-BERAT-MENINGKAT-SEDANG');
-- Harapan: Sedang(50), Tinggi(85), Tinggi(85), Tinggi(85)
--          skor = (0,5*50 + 0,5*85*3) / 2 = 76,25 -> 76 -> kategori Tinggi
