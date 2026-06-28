-- ============================================================
-- TradePro MVP — Supabase Schema
-- كل جدول محمي بـ RLS ومدعوم للـ Offline-First Sync
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE profiles (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name     TEXT NOT NULL DEFAULT '',
  trade_type    TEXT NOT NULL DEFAULT 'general'
                CHECK (trade_type IN ('electrician','plumber','hvac','carpenter','general')),
  phone         TEXT DEFAULT '',
  business_name TEXT DEFAULT '',
  logo_url      TEXT DEFAULT '',
  invoice_prefix TEXT DEFAULT 'INV-',
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles_select" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "profiles_insert" ON profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "profiles_update" ON profiles FOR UPDATE USING (auth.uid() = id);

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

CREATE TABLE customers (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  contractor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  local_id      TEXT UNIQUE,
  name          TEXT NOT NULL,
  phone         TEXT DEFAULT '',
  address       TEXT DEFAULT '',
  notes         TEXT DEFAULT '',
  is_deleted    BOOLEAN NOT NULL DEFAULT FALSE,
  is_synced     BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_customers_contractor ON customers(contractor_id);
CREATE INDEX idx_customers_updated ON customers(updated_at);

ALTER TABLE customers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers_select" ON customers FOR SELECT USING (auth.uid() = contractor_id);
CREATE POLICY "customers_insert" ON customers FOR INSERT WITH CHECK (auth.uid() = contractor_id);
CREATE POLICY "customers_update" ON customers FOR UPDATE USING (auth.uid() = contractor_id);

CREATE TABLE jobs (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  contractor_id  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  customer_id    UUID NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
  local_id       TEXT UNIQUE,
  title          TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'scheduled'
                 CHECK (status IN ('scheduled','in_progress','done','invoiced','cancelled')),
  scheduled_at   TIMESTAMPTZ,
  completed_at   TIMESTAMPTZ,
  labor_hours    DECIMAL(8,2) DEFAULT 0,
  labor_rate     DECIMAL(10,2) DEFAULT 0,
  notes          TEXT DEFAULT '',
  is_deleted     BOOLEAN NOT NULL DEFAULT FALSE,
  is_synced      BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_jobs_contractor ON jobs(contractor_id);
CREATE INDEX idx_jobs_customer ON jobs(customer_id);
CREATE INDEX idx_jobs_status ON jobs(status);
CREATE INDEX idx_jobs_updated ON jobs(updated_at);

ALTER TABLE jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "jobs_select" ON jobs FOR SELECT USING (auth.uid() = contractor_id);
CREATE POLICY "jobs_insert" ON jobs FOR INSERT WITH CHECK (auth.uid() = contractor_id);
CREATE POLICY "jobs_update" ON jobs FOR UPDATE USING (auth.uid() = contractor_id);

CREATE TABLE job_materials (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  job_id        UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  contractor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  local_id      TEXT UNIQUE,
  name          TEXT NOT NULL,
  quantity      DECIMAL(10,3) NOT NULL DEFAULT 1,
  unit_price    DECIMAL(10,2) NOT NULL DEFAULT 0,
  unit          TEXT DEFAULT 'piece',
  is_synced     BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_materials_job ON job_materials(job_id);
CREATE INDEX idx_materials_contractor ON job_materials(contractor_id);

ALTER TABLE job_materials ENABLE ROW LEVEL SECURITY;

CREATE POLICY "job_materials_select" ON job_materials FOR SELECT USING (auth.uid() = contractor_id);
CREATE POLICY "job_materials_insert" ON job_materials FOR INSERT WITH CHECK (auth.uid() = contractor_id);
CREATE POLICY "job_materials_update" ON job_materials FOR UPDATE USING (auth.uid() = contractor_id);
CREATE POLICY "job_materials_delete" ON job_materials FOR DELETE USING (auth.uid() = contractor_id);

CREATE TABLE invoices (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  job_id         UUID NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE RESTRICT,
  contractor_id  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  local_id       TEXT UNIQUE,
  invoice_number TEXT NOT NULL,
  subtotal       DECIMAL(12,2) NOT NULL DEFAULT 0,
  tax_rate       DECIMAL(5,2) NOT NULL DEFAULT 0,
  total          DECIMAL(12,2) NOT NULL DEFAULT 0,
  status         TEXT NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','sent','paid','overdue')),
  sent_at        TIMESTAMPTZ,
  paid_at        TIMESTAMPTZ,
  due_date       DATE,
  notes          TEXT DEFAULT '',
  is_synced      BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_invoices_contractor ON invoices(contractor_id);
CREATE INDEX idx_invoices_status ON invoices(status);
CREATE INDEX idx_invoices_job ON invoices(job_id);

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "invoices_select" ON invoices FOR SELECT USING (auth.uid() = contractor_id);
CREATE POLICY "invoices_insert" ON invoices FOR INSERT WITH CHECK (auth.uid() = contractor_id);
CREATE POLICY "invoices_update" ON invoices FOR UPDATE USING (auth.uid() = contractor_id);

CREATE TABLE materials_catalog (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  contractor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  local_id      TEXT UNIQUE,
  name          TEXT NOT NULL,
  default_price DECIMAL(10,2) NOT NULL DEFAULT 0,
  unit          TEXT DEFAULT 'piece',
  category      TEXT DEFAULT 'general',
  is_synced     BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_catalog_contractor ON materials_catalog(contractor_id);

ALTER TABLE materials_catalog ENABLE ROW LEVEL SECURITY;

CREATE POLICY "catalog_select" ON materials_catalog FOR SELECT USING (auth.uid() = contractor_id);
CREATE POLICY "catalog_insert" ON materials_catalog FOR INSERT WITH CHECK (auth.uid() = contractor_id);
CREATE POLICY "catalog_update" ON materials_catalog FOR UPDATE USING (auth.uid() = contractor_id);
CREATE POLICY "catalog_delete" ON materials_catalog FOR DELETE USING (auth.uid() = contractor_id);

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at_customers
  BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_jobs
  BEFORE UPDATE ON jobs FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_job_materials
  BEFORE UPDATE ON job_materials FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_invoices
  BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_catalog
  BEFORE UPDATE ON materials_catalog FOR EACH ROW EXECUTE FUNCTION update_updated_at();
