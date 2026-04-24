-- =============================================================================
-- HR Centralized CV Platform — PostgreSQL Schema (Idempotent / Re-runnable)
-- Version: 1.2  |  April 2026
-- Database: PostgreSQL 16+
--
-- Safe to run multiple times: uses IF NOT EXISTS, CREATE OR REPLACE,
-- DROP … IF EXISTS, and ON CONFLICT DO NOTHING throughout.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. EXTENSIONS
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- pgvector is optional (needed for AI embedding column in Section 11).
-- Wrapped in a DO block so the rest of the script continues if not installed.
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS "vector";
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pgvector extension not available — embedding features will be skipped. Install from https://github.com/pgvector/pgvector';
END;
$$;

-- -----------------------------------------------------------------------------
-- 0.1  Immutable unaccent wrapper
--      unaccent() is STABLE by default; indexes require IMMUTABLE functions.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION f_unaccent(text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS
$$SELECT public.unaccent('public.unaccent', $1)$$;

-- -----------------------------------------------------------------------------
-- 0.2  Auto-update updated_at trigger function
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- =============================================================================
-- 1. AUTH & USERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1  organizations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS organizations (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name              VARCHAR(255)  NOT NULL,
  slug              VARCHAR(100)  NOT NULL,
  domain            VARCHAR(255),
  subscription_plan VARCHAR(50)   NOT NULL DEFAULT 'free',
  max_users         SMALLINT      NOT NULL DEFAULT 5,
  max_cv_per_month  INT           NOT NULL DEFAULT 100,
  settings          JSONB         NOT NULL DEFAULT '{}',
  is_active         BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ,

  CONSTRAINT organizations_subscription_plan_check
    CHECK (subscription_plan IN ('free','pro','enterprise'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_organizations_slug
  ON organizations (slug)
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_organizations_updated_at ON organizations;
CREATE TRIGGER trg_organizations_updated_at
  BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 1.2  roles
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roles (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         REFERENCES organizations (id) ON DELETE CASCADE,
  name             VARCHAR(100) NOT NULL,
  permissions      JSONB        NOT NULL DEFAULT '[]',
  is_system        BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT roles_unique_per_org UNIQUE (organization_id, name)
);

CREATE INDEX IF NOT EXISTS idx_roles_org ON roles (organization_id);

-- -----------------------------------------------------------------------------
-- 1.3  users
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID          NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  email             VARCHAR(255)  NOT NULL,
  password_hash     VARCHAR(255),
  full_name         VARCHAR(255)  NOT NULL,
  avatar_url        TEXT,
  role_id           UUID          NOT NULL REFERENCES roles (id),
  is_active         BOOLEAN       NOT NULL DEFAULT TRUE,
  is_email_verified BOOLEAN       NOT NULL DEFAULT FALSE,
  last_login_at     TIMESTAMPTZ,
  login_count       INT           NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email
  ON users (email)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_users_org_role
  ON users (organization_id, role_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_users_org_active
  ON users (organization_id, is_active)
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 1.4  user_sessions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_sessions (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash     VARCHAR(64)  NOT NULL,
  ip_address     INET,
  user_agent     TEXT,
  device_info    JSONB,
  expires_at     TIMESTAMPTZ  NOT NULL,
  last_active_at TIMESTAMPTZ,
  revoked_at     TIMESTAMPTZ,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Fix: removed "expires_at > NOW()" — NOW() is volatile and not allowed in
-- index predicates. Expiry is enforced at query time instead.
CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_token_active
  ON user_sessions (token_hash)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_sessions_user
  ON user_sessions (user_id, expires_at DESC);

-- -----------------------------------------------------------------------------
-- 1.5  password_reset_tokens
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS password_reset_tokens (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash  VARCHAR(64)  NOT NULL,
  expires_at  TIMESTAMPTZ  NOT NULL,
  used_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pwd_reset_token
  ON password_reset_tokens (token_hash)
  WHERE used_at IS NULL;

-- =============================================================================
-- 2. SOURCES & FILE STORAGE
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1  cv_sources
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cv_sources (
  id                 UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  code               VARCHAR(50)  NOT NULL UNIQUE,
  name               VARCHAR(100) NOT NULL,
  type               VARCHAR(50)  NOT NULL,
  icon_url           TEXT,
  integration_config JSONB,
  is_active          BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT cv_sources_type_check
    CHECK (type IN ('job_board','social_network','email','manual'))
);

INSERT INTO cv_sources (code, name, type) VALUES
  ('topcv',    'TopCV',         'job_board'),
  ('itviec',   'ITViec',        'job_board'),
  ('linkedin', 'LinkedIn',      'social_network'),
  ('facebook', 'Facebook',      'social_network'),
  ('zalo',     'Zalo',          'social_network'),
  ('email',    'Email',         'email'),
  ('manual',   'Manual Upload', 'manual')
ON CONFLICT (code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2.2  org_source_integrations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS org_source_integrations (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  source_id        UUID         NOT NULL REFERENCES cv_sources (id),
  credentials      JSONB        NOT NULL DEFAULT '{}',
  config           JSONB        NOT NULL DEFAULT '{}',
  last_sync_at     TIMESTAMPTZ,
  sync_status      VARCHAR(50)  NOT NULL DEFAULT 'idle',
  error_message    TEXT,
  is_active        BOOLEAN      NOT NULL DEFAULT TRUE,
  created_by       UUID         REFERENCES users (id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT org_source_integrations_unique UNIQUE (organization_id, source_id),
  CONSTRAINT org_source_integrations_status_check
    CHECK (sync_status IN ('idle','running','error'))
);

CREATE INDEX IF NOT EXISTS idx_org_integrations_org
  ON org_source_integrations (organization_id, is_active);

DROP TRIGGER IF EXISTS trg_org_integrations_updated_at ON org_source_integrations;
CREATE TRIGGER trg_org_integrations_updated_at
  BEFORE UPDATE ON org_source_integrations
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 2.3  import_jobs
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS import_jobs (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  integration_id   UUID         NOT NULL REFERENCES org_source_integrations (id),
  initiated_by     UUID         REFERENCES users (id) ON DELETE SET NULL,
  status           VARCHAR(50)  NOT NULL DEFAULT 'pending',
  total_count      INT          NOT NULL DEFAULT 0,
  processed_count  INT          NOT NULL DEFAULT 0,
  success_count    INT          NOT NULL DEFAULT 0,
  failed_count     INT          NOT NULL DEFAULT 0,
  error_summary    JSONB,
  started_at       TIMESTAMPTZ,
  completed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT import_jobs_status_check
    CHECK (status IN ('pending','running','completed','failed','partial'))
);

CREATE INDEX IF NOT EXISTS idx_import_jobs_org_status
  ON import_jobs (organization_id, status, created_at DESC);

-- -----------------------------------------------------------------------------
-- 2.4  file_objects
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS file_objects (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID          NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  bucket           VARCHAR(255)  NOT NULL,
  key              TEXT          NOT NULL UNIQUE,
  filename         VARCHAR(500)  NOT NULL,
  mime_type        VARCHAR(100)  NOT NULL,
  file_size        BIGINT        NOT NULL,
  checksum_sha256  VARCHAR(64),
  storage_provider VARCHAR(50)   NOT NULL DEFAULT 's3',
  upload_status    VARCHAR(50)   NOT NULL DEFAULT 'pending',
  uploaded_by      UUID          REFERENCES users (id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  expires_at       TIMESTAMPTZ,
  deleted_at       TIMESTAMPTZ,

  CONSTRAINT file_objects_provider_check
    CHECK (storage_provider IN ('s3','minio','gcs')),
  CONSTRAINT file_objects_status_check
    CHECK (upload_status IN ('pending','complete','failed'))
);

CREATE INDEX IF NOT EXISTS idx_file_objects_org_checksum
  ON file_objects (organization_id, checksum_sha256)
  WHERE checksum_sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_file_objects_org_status
  ON file_objects (organization_id, upload_status)
  WHERE deleted_at IS NULL;

-- =============================================================================
-- 3. CANDIDATES & CVS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1  candidates
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS candidates (
  id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id         UUID          NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  canonical_email         VARCHAR(255),
  canonical_phone         VARCHAR(50),
  full_name               VARCHAR(255)  NOT NULL,
  current_title           VARCHAR(255),
  current_company         VARCHAR(255),
  location                JSONB,
  linkedin_url            TEXT,
  avatar_file_id          UUID          REFERENCES file_objects (id) ON DELETE SET NULL,
  total_experience_months INT,
  seniority_level         VARCHAR(50),
  data_sources            JSONB         NOT NULL DEFAULT '[]',
  external_ids            JSONB         NOT NULL DEFAULT '{}',
  is_merged               BOOLEAN       NOT NULL DEFAULT FALSE,
  merged_into_id          UUID          REFERENCES candidates (id) ON DELETE SET NULL,
  search_vector           TSVECTOR,
  created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at              TIMESTAMPTZ,

  CONSTRAINT candidates_seniority_check
    CHECK (seniority_level IN ('intern','junior','mid','senior','lead','manager','director')
           OR seniority_level IS NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_candidates_org_email
  ON candidates (organization_id, canonical_email)
  WHERE canonical_email IS NOT NULL AND deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_candidates_org_phone
  ON candidates (organization_id, canonical_phone)
  WHERE canonical_phone IS NOT NULL AND deleted_at IS NULL;

-- Fix: use f_unaccent() (IMMUTABLE wrapper) instead of unaccent() (STABLE).
-- Standard indexes require IMMUTABLE functions in their expressions.
CREATE INDEX IF NOT EXISTS idx_candidates_name_trgm
  ON candidates USING GIN (f_unaccent(full_name) gin_trgm_ops)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_candidates_fts
  ON candidates USING GIN (search_vector)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_candidates_data_sources
  ON candidates USING GIN (data_sources)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_candidates_external_ids
  ON candidates USING GIN (external_ids);

-- Trigger: rebuild search_vector on every insert/update
CREATE OR REPLACE FUNCTION fn_candidates_search_vector()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_vector :=
    to_tsvector('simple',
      f_unaccent(COALESCE(NEW.full_name, '')) || ' ' ||
      f_unaccent(COALESCE(NEW.current_title, '')) || ' ' ||
      f_unaccent(COALESCE(NEW.current_company, ''))
    );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_candidates_search_vector ON candidates;
CREATE TRIGGER trg_candidates_search_vector
  BEFORE INSERT OR UPDATE ON candidates
  FOR EACH ROW EXECUTE FUNCTION fn_candidates_search_vector();

DROP TRIGGER IF EXISTS trg_candidates_updated_at ON candidates;
CREATE TRIGGER trg_candidates_updated_at
  BEFORE UPDATE ON candidates
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 3.2  candidate_contact_infos
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS candidate_contact_infos (
  id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id  UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  type          VARCHAR(50)  NOT NULL,
  value         TEXT         NOT NULL,
  is_primary    BOOLEAN      NOT NULL DEFAULT FALSE,
  is_verified   BOOLEAN      NOT NULL DEFAULT FALSE,
  source_id     UUID         REFERENCES cv_sources (id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT candidate_contact_unique UNIQUE (candidate_id, type, value),
  CONSTRAINT candidate_contact_type_check
    CHECK (type IN ('email','phone','linkedin','facebook','zalo','website','github','other'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_candidate_contact_primary
  ON candidate_contact_infos (candidate_id, type)
  WHERE is_primary = TRUE;

CREATE INDEX IF NOT EXISTS idx_candidate_contact_type
  ON candidate_contact_infos (candidate_id, type);

-- -----------------------------------------------------------------------------
-- 3.3  cvs
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cvs (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id      UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  organization_id   UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  file_id           UUID         NOT NULL REFERENCES file_objects (id),
  source_id         UUID         NOT NULL REFERENCES cv_sources (id),
  import_job_id     UUID         REFERENCES import_jobs (id) ON DELETE SET NULL,
  external_url      TEXT,
  language          VARCHAR(10)  NOT NULL DEFAULT 'vi',
  version           SMALLINT     NOT NULL DEFAULT 1,
  is_latest         BOOLEAN      NOT NULL DEFAULT TRUE,
  processing_status VARCHAR(50)  NOT NULL DEFAULT 'pending',
  processing_error  TEXT,
  uploaded_by       UUID         REFERENCES users (id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT cvs_status_check
    CHECK (processing_status IN ('pending','processing','extracted','failed'))
);

CREATE INDEX IF NOT EXISTS idx_cvs_candidate_latest
  ON cvs (candidate_id, is_latest)
  WHERE is_latest = TRUE;

CREATE INDEX IF NOT EXISTS idx_cvs_org_status
  ON cvs (organization_id, processing_status)
  WHERE processing_status IN ('pending','failed');

CREATE INDEX IF NOT EXISTS idx_cvs_import_job ON cvs (import_job_id);

DROP TRIGGER IF EXISTS trg_cvs_updated_at ON cvs;
CREATE TRIGGER trg_cvs_updated_at
  BEFORE UPDATE ON cvs
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 3.4  cv_extractions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cv_extractions (
  id                        UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  cv_id                     UUID          NOT NULL REFERENCES cvs (id) ON DELETE CASCADE,
  model_provider            VARCHAR(50)   NOT NULL,
  model_version             VARCHAR(100)  NOT NULL,
  extraction_schema_version SMALLINT      NOT NULL DEFAULT 1,
  raw_text                  TEXT,
  extracted_data            JSONB         NOT NULL DEFAULT '{}',
  summary                   TEXT,
  top_skills                JSONB         NOT NULL DEFAULT '[]',
  seniority_level           VARCHAR(50),
  total_experience_months   INT,
  -- embedding column lives in Section 11 (requires pgvector)
  confidence_score          DECIMAL(3,2),
  token_count               INT,
  processing_ms             INT,
  error_message             TEXT,
  extracted_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  created_at                TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT cv_extractions_unique
    UNIQUE (cv_id, model_version, extraction_schema_version),
  CONSTRAINT cv_extractions_confidence_check
    CHECK (confidence_score IS NULL OR (confidence_score BETWEEN 0 AND 1))
);

CREATE INDEX IF NOT EXISTS idx_cv_extractions_cv
  ON cv_extractions (cv_id, extraction_schema_version DESC);

CREATE INDEX IF NOT EXISTS idx_cv_extractions_skills
  ON cv_extractions USING GIN (top_skills);

-- =============================================================================
-- 4. CANDIDATE PROFILE (NORMALIZED)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1  skill_categories
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS skill_categories (
  id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  name                VARCHAR(100) NOT NULL,
  parent_category_id  UUID         REFERENCES skill_categories (id) ON DELETE SET NULL,
  order_index         SMALLINT     NOT NULL DEFAULT 0,

  CONSTRAINT skill_categories_unique UNIQUE (name)
);

INSERT INTO skill_categories (name, order_index) VALUES
  ('Programming Languages', 1),
  ('Frontend',              2),
  ('Backend',               3),
  ('Database',              4),
  ('DevOps & Cloud',        5),
  ('Mobile',                6),
  ('AI / Machine Learning', 7),
  ('Soft Skills',           8),
  ('Management',            9),
  ('Other',                99)
ON CONFLICT (name) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4.2  skills
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS skills (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name             VARCHAR(255)  NOT NULL UNIQUE,
  normalized_name  VARCHAR(255)  NOT NULL UNIQUE,
  category_id      UUID          REFERENCES skill_categories (id) ON DELETE SET NULL,
  parent_skill_id  UUID          REFERENCES skills (id) ON DELETE SET NULL,
  aliases          JSONB         NOT NULL DEFAULT '[]',
  is_technical     BOOLEAN       NOT NULL DEFAULT TRUE,
  popularity_score INT           NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_skills_category ON skills (category_id);

CREATE INDEX IF NOT EXISTS idx_skills_name_trgm
  ON skills USING GIN (normalized_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_skills_aliases
  ON skills USING GIN (aliases);

DROP TRIGGER IF EXISTS trg_skills_updated_at ON skills;
CREATE TRIGGER trg_skills_updated_at
  BEFORE UPDATE ON skills
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 4.3  candidate_skills
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS candidate_skills (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id      UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  skill_id          UUID         NOT NULL REFERENCES skills (id) ON DELETE CASCADE,
  cv_extraction_id  UUID         NOT NULL REFERENCES cv_extractions (id) ON DELETE CASCADE,
  proficiency_level VARCHAR(50),
  years_experience  DECIMAL(4,1),
  source_text       TEXT,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT candidate_skills_unique UNIQUE (candidate_id, skill_id),
  CONSTRAINT candidate_skills_proficiency_check
    CHECK (proficiency_level IN ('beginner','intermediate','advanced','expert')
           OR proficiency_level IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_candidate_skills_candidate
  ON candidate_skills (candidate_id);

CREATE INDEX IF NOT EXISTS idx_candidate_skills_skill
  ON candidate_skills (skill_id, proficiency_level);

-- -----------------------------------------------------------------------------
-- 4.4  candidate_experiences
-- -----------------------------------------------------------------------------
-- Fix: removed GENERATED ALWAYS AS (CURRENT_DATE) — CURRENT_DATE is volatile
-- and PostgreSQL requires generated column expressions to be IMMUTABLE.
-- duration_months is now a plain INT maintained by a trigger.
CREATE TABLE IF NOT EXISTS candidate_experiences (
  id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id        UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  cv_extraction_id    UUID         NOT NULL REFERENCES cv_extractions (id) ON DELETE CASCADE,
  company_name        VARCHAR(500) NOT NULL,
  company_normalized  VARCHAR(500),
  title               VARCHAR(500) NOT NULL,
  title_normalized    VARCHAR(500),
  department          VARCHAR(255),
  start_date          DATE         NOT NULL,
  end_date            DATE,
  is_current          BOOLEAN      NOT NULL DEFAULT FALSE,
  location            JSONB,
  description         TEXT,
  responsibilities    JSONB        NOT NULL DEFAULT '[]',
  achievements        JSONB        NOT NULL DEFAULT '[]',
  technologies        JSONB        NOT NULL DEFAULT '[]',
  duration_months     INT,          -- maintained by trigger below
  order_index         SMALLINT     NOT NULL DEFAULT 0,
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_experiences_candidate
  ON candidate_experiences (candidate_id, start_date DESC);

CREATE INDEX IF NOT EXISTS idx_experiences_technologies
  ON candidate_experiences USING GIN (technologies);

-- Trigger: compute duration_months on insert/update (avoids CURRENT_DATE in generated column)
CREATE OR REPLACE FUNCTION fn_compute_experience_duration()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  end_d DATE := COALESCE(NEW.end_date, CURRENT_DATE);
BEGIN
  NEW.duration_months :=
    (EXTRACT(YEAR  FROM AGE(end_d, NEW.start_date))::INT * 12) +
    EXTRACT(MONTH FROM AGE(end_d, NEW.start_date))::INT;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_experience_duration ON candidate_experiences;
CREATE TRIGGER trg_experience_duration
  BEFORE INSERT OR UPDATE ON candidate_experiences
  FOR EACH ROW EXECUTE FUNCTION fn_compute_experience_duration();

-- -----------------------------------------------------------------------------
-- 4.5  candidate_educations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS candidate_educations (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id      UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  cv_extraction_id  UUID         NOT NULL REFERENCES cv_extractions (id) ON DELETE CASCADE,
  institution_name  VARCHAR(500) NOT NULL,
  degree            VARCHAR(255),
  field_of_study    VARCHAR(255),
  start_date        DATE,
  end_date          DATE,
  is_current        BOOLEAN      NOT NULL DEFAULT FALSE,
  gpa               DECIMAL(4,2),
  description       TEXT,
  order_index       SMALLINT     NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_educations_candidate
  ON candidate_educations (candidate_id, end_date DESC NULLS FIRST);

-- -----------------------------------------------------------------------------
-- 4.6  candidate_certifications
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS candidate_certifications (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id      UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  cv_extraction_id  UUID         NOT NULL REFERENCES cv_extractions (id) ON DELETE CASCADE,
  name              VARCHAR(500) NOT NULL,
  issuer            VARCHAR(255),
  issue_date        DATE,
  expiry_date       DATE,
  credential_id     VARCHAR(255),
  credential_url    TEXT,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_certifications_candidate
  ON candidate_certifications (candidate_id);

-- -----------------------------------------------------------------------------
-- 4.7  candidate_languages
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS candidate_languages (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id   UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  language_code  VARCHAR(10)  NOT NULL,
  language_name  VARCHAR(100) NOT NULL,
  proficiency    VARCHAR(50),
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT candidate_languages_unique UNIQUE (candidate_id, language_code)
);

-- =============================================================================
-- 5. JOBS & RECRUITMENT PIPELINE
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1  departments
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS departments (
  id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  name                 VARCHAR(255) NOT NULL,
  code                 VARCHAR(50),
  parent_department_id UUID         REFERENCES departments (id) ON DELETE SET NULL,
  manager_id           UUID         REFERENCES users (id) ON DELETE SET NULL,
  is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_departments_org_name
  ON departments (organization_id, name)
  WHERE is_active = TRUE;

-- -----------------------------------------------------------------------------
-- 5.2  job_positions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS job_positions (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  department_id     UUID         REFERENCES departments (id) ON DELETE SET NULL,
  title             VARCHAR(255) NOT NULL,
  code              VARCHAR(100),
  level             VARCHAR(50),
  employment_type   VARCHAR(50)  NOT NULL DEFAULT 'full_time',
  location_type     VARCHAR(50)  NOT NULL DEFAULT 'onsite',
  location          JSONB,
  headcount         SMALLINT     NOT NULL DEFAULT 1,
  status            VARCHAR(50)  NOT NULL DEFAULT 'draft',
  priority          VARCHAR(50)  NOT NULL DEFAULT 'medium',
  salary_min        BIGINT,
  salary_max        BIGINT,
  currency          VARCHAR(10)  NOT NULL DEFAULT 'VND',
  open_date         DATE,
  target_close_date DATE,
  actual_close_date DATE,
  created_by        UUID         NOT NULL REFERENCES users (id),
  hiring_manager_id UUID         REFERENCES users (id) ON DELETE SET NULL,
  recruiter_id      UUID         REFERENCES users (id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ,

  CONSTRAINT job_positions_employment_type_check
    CHECK (employment_type IN ('full_time','part_time','contract','freelance','internship')),
  CONSTRAINT job_positions_location_type_check
    CHECK (location_type IN ('onsite','remote','hybrid')),
  CONSTRAINT job_positions_status_check
    CHECK (status IN ('draft','open','paused','closed','filled')),
  CONSTRAINT job_positions_priority_check
    CHECK (priority IN ('low','medium','high','urgent')),
  CONSTRAINT job_positions_salary_check
    CHECK (salary_min IS NULL OR salary_max IS NULL OR salary_min <= salary_max)
);

CREATE INDEX IF NOT EXISTS idx_job_positions_org_status
  ON job_positions (organization_id, status)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_job_positions_recruiter
  ON job_positions (recruiter_id, status)
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_job_positions_updated_at ON job_positions;
CREATE TRIGGER trg_job_positions_updated_at
  BEFORE UPDATE ON job_positions
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 5.3  job_descriptions
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS job_descriptions (
  id                      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  position_id             UUID         NOT NULL REFERENCES job_positions (id) ON DELETE CASCADE,
  version                 SMALLINT     NOT NULL DEFAULT 1,
  title                   VARCHAR(255) NOT NULL,
  summary                 TEXT,
  responsibilities        TEXT,
  requirements            TEXT,
  nice_to_have            TEXT,
  benefits                TEXT,
  structured_requirements JSONB        NOT NULL DEFAULT '{}',
  is_ai_generated         BOOLEAN      NOT NULL DEFAULT FALSE,
  ai_task_id              UUID,
  published_channels      JSONB        NOT NULL DEFAULT '[]',
  is_current              BOOLEAN      NOT NULL DEFAULT TRUE,
  created_by              UUID         NOT NULL REFERENCES users (id),
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_jd_position_current
  ON job_descriptions (position_id)
  WHERE is_current = TRUE;

CREATE INDEX IF NOT EXISTS idx_jd_position_version
  ON job_descriptions (position_id, version DESC);

DROP TRIGGER IF EXISTS trg_jd_updated_at ON job_descriptions;
CREATE TRIGGER trg_jd_updated_at
  BEFORE UPDATE ON job_descriptions
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE OR REPLACE FUNCTION fn_jd_set_current()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_current = TRUE THEN
    UPDATE job_descriptions
    SET is_current = FALSE, updated_at = NOW()
    WHERE position_id = NEW.position_id
      AND id <> NEW.id
      AND is_current = TRUE;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_jd_set_current ON job_descriptions;
CREATE TRIGGER trg_jd_set_current
  AFTER INSERT OR UPDATE ON job_descriptions
  FOR EACH ROW WHEN (NEW.is_current = TRUE)
  EXECUTE FUNCTION fn_jd_set_current();

-- -----------------------------------------------------------------------------
-- 5.4  pipeline_stages
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pipeline_stages (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  position_id      UUID         REFERENCES job_positions (id) ON DELETE CASCADE,
  name             VARCHAR(100) NOT NULL,
  type             VARCHAR(50)  NOT NULL,
  order_index      SMALLINT     NOT NULL DEFAULT 0,
  color            VARCHAR(7),
  sla_days         SMALLINT,
  is_active        BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT pipeline_stages_type_check
    CHECK (type IN ('screening','call','interview','assessment','offer','hired','rejected'))
);

CREATE INDEX IF NOT EXISTS idx_pipeline_stages_org
  ON pipeline_stages (organization_id, position_id, order_index)
  WHERE is_active = TRUE;

-- -----------------------------------------------------------------------------
-- 5.5  applications
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS applications (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  candidate_id     UUID         NOT NULL REFERENCES candidates (id) ON DELETE CASCADE,
  position_id      UUID         NOT NULL REFERENCES job_positions (id) ON DELETE CASCADE,
  cv_id            UUID         NOT NULL REFERENCES cvs (id),
  source_id        UUID         REFERENCES cv_sources (id) ON DELETE SET NULL,
  current_stage_id UUID         NOT NULL REFERENCES pipeline_stages (id),
  status           VARCHAR(50)  NOT NULL DEFAULT 'active',
  rejection_reason VARCHAR(255),
  ai_match_score   DECIMAL(5,2),
  ai_match_details JSONB,
  assigned_to      UUID         REFERENCES users (id) ON DELETE SET NULL,
  applied_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  deleted_at       TIMESTAMPTZ,

  CONSTRAINT applications_status_check
    CHECK (status IN ('active','hired','rejected','withdrawn','on_hold')),
  CONSTRAINT applications_match_score_check
    CHECK (ai_match_score IS NULL OR ai_match_score BETWEEN 0 AND 100)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_applications_unique_active
  ON applications (candidate_id, position_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_applications_org_stage_status
  ON applications (organization_id, current_stage_id, status)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_applications_position_score
  ON applications (position_id, ai_match_score DESC NULLS LAST)
  WHERE deleted_at IS NULL AND status = 'active';

CREATE INDEX IF NOT EXISTS idx_applications_assigned
  ON applications (assigned_to, status)
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_applications_updated_at ON applications;
CREATE TRIGGER trg_applications_updated_at
  BEFORE UPDATE ON applications
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 5.6  application_stage_history  (IMMUTABLE — append only)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS application_stage_history (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  UUID         NOT NULL REFERENCES applications (id) ON DELETE CASCADE,
  from_stage_id   UUID         REFERENCES pipeline_stages (id) ON DELETE SET NULL,
  to_stage_id     UUID         NOT NULL REFERENCES pipeline_stages (id),
  changed_by      UUID         REFERENCES users (id) ON DELETE SET NULL,
  reason          TEXT,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stage_history_application
  ON application_stage_history (application_id, created_at);

CREATE OR REPLACE RULE no_update_stage_history AS
  ON UPDATE TO application_stage_history DO INSTEAD NOTHING;

CREATE OR REPLACE RULE no_delete_stage_history AS
  ON DELETE TO application_stage_history DO INSTEAD NOTHING;

CREATE OR REPLACE FUNCTION fn_track_stage_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_stage_id IS DISTINCT FROM NEW.current_stage_id THEN
    INSERT INTO application_stage_history
      (application_id, from_stage_id, to_stage_id)
    VALUES
      (NEW.id, OLD.current_stage_id, NEW.current_stage_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_track_stage_change ON applications;
CREATE TRIGGER trg_track_stage_change
  AFTER UPDATE ON applications
  FOR EACH ROW EXECUTE FUNCTION fn_track_stage_change();

-- -----------------------------------------------------------------------------
-- 5.7  interviews
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS interviews (
  id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id      UUID         NOT NULL REFERENCES applications (id) ON DELETE CASCADE,
  stage_id            UUID         REFERENCES pipeline_stages (id) ON DELETE SET NULL,
  type                VARCHAR(50)  NOT NULL,
  scheduled_at        TIMESTAMPTZ  NOT NULL,
  duration_minutes    SMALLINT     NOT NULL DEFAULT 60,
  location            TEXT,
  interviewer_ids     JSONB        NOT NULL DEFAULT '[]',
  status              VARCHAR(50)  NOT NULL DEFAULT 'scheduled',
  candidate_confirmed BOOLEAN      NOT NULL DEFAULT FALSE,
  notes               TEXT,
  outcome             VARCHAR(50),
  calendar_event_id   TEXT,
  created_by          UUID         NOT NULL REFERENCES users (id),
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT interviews_type_check
    CHECK (type IN ('phone','video','onsite','technical','hr','panel','take_home')),
  CONSTRAINT interviews_status_check
    CHECK (status IN ('scheduled','completed','cancelled','rescheduled','no_show')),
  CONSTRAINT interviews_outcome_check
    CHECK (outcome IN ('pass','fail','hold','pending') OR outcome IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_interviews_application
  ON interviews (application_id, scheduled_at);

CREATE INDEX IF NOT EXISTS idx_interviews_scheduled
  ON interviews (scheduled_at)
  WHERE status = 'scheduled';

DROP TRIGGER IF EXISTS trg_interviews_updated_at ON interviews;
CREATE TRIGGER trg_interviews_updated_at
  BEFORE UPDATE ON interviews
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 5.8  interview_feedback
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS interview_feedback (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  interview_id     UUID         NOT NULL REFERENCES interviews (id) ON DELETE CASCADE,
  interviewer_id   UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  scores           JSONB        NOT NULL DEFAULT '{}',
  overall_rating   SMALLINT     NOT NULL,
  strengths        TEXT,
  weaknesses       TEXT,
  recommendation   VARCHAR(50)  NOT NULL,
  notes            TEXT,
  submitted_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT interview_feedback_unique    UNIQUE (interview_id, interviewer_id),
  CONSTRAINT interview_feedback_rating    CHECK (overall_rating BETWEEN 1 AND 5),
  CONSTRAINT interview_feedback_recommend CHECK (
    recommendation IN ('strong_hire','hire','lean_hire','no_hire','strong_no_hire'))
);

CREATE INDEX IF NOT EXISTS idx_interview_feedback_interview
  ON interview_feedback (interview_id);

-- =============================================================================
-- 6. AI TASKS & CONVERSATIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1  ai_tasks
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_tasks (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  task_type        VARCHAR(100) NOT NULL,
  status           VARCHAR(50)  NOT NULL DEFAULT 'queued',
  priority         SMALLINT     NOT NULL DEFAULT 5,
  input_type       VARCHAR(50)  NOT NULL,
  input_id         UUID         NOT NULL,
  input_data       JSONB        NOT NULL DEFAULT '{}',
  output_data      JSONB,
  model_provider   VARCHAR(50),
  model_version    VARCHAR(100),
  token_input      INT,
  token_output     INT,
  cost_usd         DECIMAL(10,6),
  error_message    TEXT,
  retry_count      SMALLINT     NOT NULL DEFAULT 0,
  max_retries      SMALLINT     NOT NULL DEFAULT 3,
  queued_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  started_at       TIMESTAMPTZ,
  completed_at     TIMESTAMPTZ,
  created_by       UUID         REFERENCES users (id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT ai_tasks_status_check
    CHECK (status IN ('queued','processing','completed','failed','cancelled')),
  CONSTRAINT ai_tasks_priority_check
    CHECK (priority BETWEEN 1 AND 10)
);

CREATE INDEX IF NOT EXISTS idx_ai_tasks_queue
  ON ai_tasks (priority ASC, queued_at ASC)
  WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_ai_tasks_org_status
  ON ai_tasks (organization_id, task_type, status, created_at DESC);

-- Deferred FK from job_descriptions → ai_tasks (ai_tasks created after job_descriptions)
ALTER TABLE job_descriptions
  ADD COLUMN IF NOT EXISTS ai_task_id UUID;   -- no-op if already present

DO $$
BEGIN
  ALTER TABLE job_descriptions
    ADD CONSTRAINT fk_jd_ai_task
    FOREIGN KEY (ai_task_id) REFERENCES ai_tasks (id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN
  NULL;  -- constraint already exists, skip
END;
$$;

-- -----------------------------------------------------------------------------
-- 6.2  ai_conversations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_conversations (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  user_id          UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  context_type     VARCHAR(50)  NOT NULL,
  context_id       UUID,
  title            VARCHAR(500),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  deleted_at       TIMESTAMPTZ,

  CONSTRAINT ai_conversations_context_check
    CHECK (context_type IN ('candidate','cv','position','general'))
);

CREATE INDEX IF NOT EXISTS idx_ai_conversations_user
  ON ai_conversations (user_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_ai_conversations_context
  ON ai_conversations (context_type, context_id)
  WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS trg_ai_conversations_updated_at ON ai_conversations;
CREATE TRIGGER trg_ai_conversations_updated_at
  BEFORE UPDATE ON ai_conversations
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.3  ai_messages
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_messages (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  UUID         NOT NULL REFERENCES ai_conversations (id) ON DELETE CASCADE,
  role             VARCHAR(20)  NOT NULL,
  content          TEXT         NOT NULL,
  input_tokens     INT,
  output_tokens    INT,
  model_version    VARCHAR(100),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT ai_messages_role_check
    CHECK (role IN ('user','assistant','system'))
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_conversation
  ON ai_messages (conversation_id, created_at);

-- =============================================================================
-- 7. SYSTEM, ANALYTICS & TAGS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 7.1  notifications  (partitioned quarterly)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
  id               UUID         NOT NULL DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  user_id          UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  type             VARCHAR(100) NOT NULL,
  title            VARCHAR(500) NOT NULL,
  body             TEXT,
  data             JSONB        NOT NULL DEFAULT '{}',
  read_at          TIMESTAMPTZ,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS notifications_2026_q1
  PARTITION OF notifications
  FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');

CREATE TABLE IF NOT EXISTS notifications_2026_q2
  PARTITION OF notifications
  FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

CREATE TABLE IF NOT EXISTS notifications_2026_q3
  PARTITION OF notifications
  FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

CREATE TABLE IF NOT EXISTS notifications_2026_q4
  PARTITION OF notifications
  FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON notifications (user_id, created_at DESC)
  WHERE read_at IS NULL;

-- -----------------------------------------------------------------------------
-- 7.2  audit_logs  (partitioned monthly — APPEND ONLY)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
  id               UUID         NOT NULL DEFAULT gen_random_uuid(),
  organization_id  UUID,
  user_id          UUID,
  session_id       UUID,
  action           VARCHAR(100) NOT NULL,
  entity_type      VARCHAR(100) NOT NULL,
  entity_id        UUID,
  old_data         JSONB,
  new_data         JSONB,
  ip_address       INET,
  user_agent       TEXT,
  request_id       VARCHAR(64),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE IF NOT EXISTS audit_logs_2026_01 PARTITION OF audit_logs FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_02 PARTITION OF audit_logs FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_03 PARTITION OF audit_logs FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_04 PARTITION OF audit_logs FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_05 PARTITION OF audit_logs FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_06 PARTITION OF audit_logs FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_07 PARTITION OF audit_logs FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_08 PARTITION OF audit_logs FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_09 PARTITION OF audit_logs FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_10 PARTITION OF audit_logs FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_11 PARTITION OF audit_logs FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS audit_logs_2026_12 PARTITION OF audit_logs FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

CREATE INDEX IF NOT EXISTS idx_audit_logs_entity
  ON audit_logs (organization_id, entity_type, entity_id, created_at);

CREATE INDEX IF NOT EXISTS idx_audit_logs_user
  ON audit_logs (organization_id, user_id, created_at);

CREATE OR REPLACE RULE no_update_audit_logs AS
  ON UPDATE TO audit_logs DO INSTEAD NOTHING;

CREATE OR REPLACE RULE no_delete_audit_logs AS
  ON DELETE TO audit_logs DO INSTEAD NOTHING;

-- -----------------------------------------------------------------------------
-- 7.3  dashboard_metrics
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dashboard_metrics (
  id               UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID           NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  metric_date      DATE           NOT NULL,
  metric_type      VARCHAR(100)   NOT NULL,
  dimension        JSONB          NOT NULL DEFAULT '{}',
  value            DECIMAL(15,4)  NOT NULL,
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_dashboard_metrics_unique
  ON dashboard_metrics (organization_id, metric_date, metric_type, (dimension::TEXT));

CREATE INDEX IF NOT EXISTS idx_dashboard_metrics_query
  ON dashboard_metrics (organization_id, metric_type, metric_date);

-- -----------------------------------------------------------------------------
-- 7.4  tags
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tags (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID         NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  name             VARCHAR(100) NOT NULL,
  color            VARCHAR(7),
  entity_type      VARCHAR(50)  NOT NULL,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT tags_unique UNIQUE (organization_id, name, entity_type),
  CONSTRAINT tags_entity_type_check
    CHECK (entity_type IN ('candidate','job_position'))
);

-- -----------------------------------------------------------------------------
-- 7.5  entity_tags
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS entity_tags (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  tag_id       UUID         NOT NULL REFERENCES tags (id) ON DELETE CASCADE,
  entity_id    UUID         NOT NULL,
  entity_type  VARCHAR(50)  NOT NULL,
  created_by   UUID         NOT NULL REFERENCES users (id),
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT entity_tags_unique UNIQUE (tag_id, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_entity_tags_entity
  ON entity_tags (entity_id, entity_type);

-- =============================================================================
-- 8. MATERIALIZED VIEWS
-- =============================================================================

-- Fix: window function LEAD() pre-computed in CTE before AVG() aggregates it.
-- Fix: DROP ... IF EXISTS so the view can be recreated on re-runs.
DROP MATERIALIZED VIEW IF EXISTS mv_pipeline_funnel;
CREATE MATERIALIZED VIEW mv_pipeline_funnel AS
WITH stage_durations AS (
  SELECT
    a.organization_id,
    a.position_id,
    a.id                                                             AS application_id,
    h.to_stage_id,
    EXTRACT(EPOCH FROM (
      LEAD(h.created_at) OVER (PARTITION BY h.application_id ORDER BY h.created_at)
      - h.created_at
    )) / 86400.0                                                     AS days_in_stage
  FROM applications a
  JOIN application_stage_history h ON h.application_id = a.id
  WHERE a.deleted_at IS NULL
)
SELECT
  sd.organization_id,
  sd.position_id,
  ps.name                             AS stage_name,
  ps.type                             AS stage_type,
  ps.order_index,
  COUNT(DISTINCT sd.application_id)   AS candidate_count,
  AVG(sd.days_in_stage)               AS avg_days_in_stage
FROM stage_durations sd
JOIN pipeline_stages ps ON ps.id = sd.to_stage_id
GROUP BY 1, 2, 3, 4, 5;

CREATE UNIQUE INDEX ON mv_pipeline_funnel (organization_id, position_id, stage_name);

DROP MATERIALIZED VIEW IF EXISTS mv_cv_source_stats;
CREATE MATERIALIZED VIEW mv_cv_source_stats AS
SELECT
  c.organization_id,
  s.code   AS source_code,
  s.name   AS source_name,
  COUNT(*) AS total_cvs,
  COUNT(*) FILTER (WHERE cv.processing_status = 'extracted') AS extracted_cvs,
  MIN(cv.created_at) AS first_import_at,
  MAX(cv.created_at) AS last_import_at
FROM cvs cv
JOIN candidates c ON c.id = cv.candidate_id
JOIN cv_sources s ON s.id = cv.source_id
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX ON mv_cv_source_stats (organization_id, source_code);

-- =============================================================================
-- 9. ROW-LEVEL SECURITY (MULTI-TENANCY)
-- =============================================================================
-- Only tables that carry organization_id directly receive the simple policy.
-- Child tables are protected transitively through parent FKs + app-layer joins.
-- Application sets: SET LOCAL app.current_org_id = '<uuid>';

DO $$
DECLARE
  t TEXT;
  tables TEXT[] := ARRAY[
    'users', 'roles', 'org_source_integrations', 'import_jobs', 'file_objects',
    'candidates', 'cvs',
    'departments', 'job_positions', 'pipeline_stages',
    'applications',
    'ai_tasks', 'ai_conversations',
    'tags', 'dashboard_metrics'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    BEGIN
      EXECUTE format(
        'CREATE POLICY tenant_isolation ON %I
         USING (organization_id = current_setting(''app.current_org_id'', TRUE)::UUID)',
        t
      );
    EXCEPTION WHEN duplicate_object THEN
      NULL;  -- policy already exists, skip silently
    END;
  END LOOP;
END;
$$;

-- =============================================================================
-- 10. VIEWS
-- =============================================================================

CREATE OR REPLACE VIEW v_candidate_overview AS
SELECT
  c.id,
  c.organization_id,
  c.full_name,
  c.canonical_email,
  c.canonical_phone,
  c.current_title,
  c.current_company,
  c.seniority_level,
  c.total_experience_months,
  c.data_sources,
  cv.id          AS latest_cv_id,
  cv.source_id   AS latest_cv_source_id,
  cv.created_at  AS cv_received_at,
  e.summary      AS ai_summary,
  e.top_skills,
  e.confidence_score,
  c.created_at,
  c.updated_at
FROM candidates c
LEFT JOIN cvs cv
  ON cv.candidate_id = c.id AND cv.is_latest = TRUE
LEFT JOIN cv_extractions e
  ON e.cv_id = cv.id
  AND e.extraction_schema_version = (
    SELECT MAX(extraction_schema_version)
    FROM cv_extractions
    WHERE cv_id = cv.id
  )
WHERE c.deleted_at IS NULL;

CREATE OR REPLACE VIEW v_active_applications AS
SELECT
  a.id,
  a.organization_id,
  a.candidate_id,
  c.full_name       AS candidate_name,
  c.current_title   AS candidate_title,
  a.position_id,
  jp.title          AS position_title,
  ps.name           AS current_stage,
  ps.type           AS stage_type,
  ps.order_index,
  a.status,
  a.ai_match_score,
  a.assigned_to,
  a.applied_at,
  a.updated_at
FROM applications a
JOIN candidates      c  ON c.id  = a.candidate_id
JOIN job_positions   jp ON jp.id = a.position_id
JOIN pipeline_stages ps ON ps.id = a.current_stage_id
WHERE a.deleted_at IS NULL AND a.status = 'active';

-- =============================================================================
-- 11. OPTIONAL — pgvector semantic search
-- =============================================================================
-- Run this block only after confirming pgvector is installed:
--   SELECT * FROM pg_available_extensions WHERE name = 'vector';
--
-- Uncomment and execute to add the embedding column + ANN index:

-- ALTER TABLE cv_extractions
--   ADD COLUMN IF NOT EXISTS embedding vector(1536);
--
-- CREATE INDEX IF NOT EXISTS idx_cv_extractions_embedding
--   ON cv_extractions USING ivfflat (embedding vector_cosine_ops)
--   WITH (lists = 100);

-- =============================================================================
-- END OF SCHEMA
-- =============================================================================
