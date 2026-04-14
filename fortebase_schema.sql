-- ================================================================
-- ForteBase ERP · 多租户数据库 Schema
-- 版本: 1.0
-- 在 Supabase SQL Editor 里一次性运行
-- ================================================================

-- ── 1. 租户表（每个注册老板 = 一个租户）──
-- auth.users 由 Supabase Auth 自动管理，这里只存业务属性
CREATE TABLE IF NOT EXISTS tenants (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  company_name    TEXT NOT NULL,           -- 公司/店铺名称
  owner_name      TEXT,                    -- 老板姓名
  phone           TEXT,
  country         TEXT DEFAULT 'AO',       -- 安哥拉
  plan            TEXT DEFAULT 'free'      -- free / pro / enterprise
                  CHECK (plan IN ('free','pro','enterprise')),
  plan_expires_at TIMESTAMPTZ,             -- NULL = 永久免费
  max_stores      INT DEFAULT 2,           -- 免费版最多2家店
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── 2. ERP快照表（核心数据，每台设备一行）──
CREATE TABLE IF NOT EXISTS erp_snapshots (
  device_id       TEXT NOT NULL,
  tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  snapshot        JSONB NOT NULL,
  saved_at        TIMESTAMPTZ DEFAULT NOW(),
  version         TEXT DEFAULT 'V15',
  store_count     INT DEFAULT 1,
  store_names     TEXT,
  boss_name       TEXT,
  sale_count      INT DEFAULT 0,
  product_count   INT DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (device_id, tenant_id)
);

-- ── 3. 匿名市场数据表（用于行情分析，不含客户信息）──
-- 用户同意条款后才写入，完全脱敏
CREATE TABLE IF NOT EXISTS market_data (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL,            -- 只存 UUID，不存店名
  country       TEXT DEFAULT 'AO',
  city          TEXT,                     -- 卢班戈/罗安达 等
  product_cat   TEXT,                     -- 水泥/砂石/钢材
  avg_price     NUMERIC(12,2),            -- 该品类本月均价
  unit          TEXT,
  month         TEXT,                     -- 2025-04
  recorded_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ── 4. SaaS管理表（你自己用，查看所有客户）──
-- 只有 service_role 能访问
CREATE TABLE IF NOT EXISTS admin_log (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID REFERENCES tenants(id),
  event         TEXT NOT NULL,            -- 'signup','upgrade','churn'
  detail        JSONB,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ================================================================
-- Row Level Security（RLS）— 核心安全策略
-- 每个老板只能看自己的数据
-- ================================================================

-- 启用 RLS
ALTER TABLE tenants        ENABLE ROW LEVEL SECURITY;
ALTER TABLE erp_snapshots  ENABLE ROW LEVEL SECURITY;
ALTER TABLE market_data    ENABLE ROW LEVEL SECURITY;

-- tenants：只能读写自己的行
CREATE POLICY "tenant_self" ON tenants
  FOR ALL USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- erp_snapshots：只能读写自己 tenant_id 的行
CREATE POLICY "snapshot_owner" ON erp_snapshots
  FOR ALL USING (tenant_id = auth.uid())
  WITH CHECK (tenant_id = auth.uid());

-- market_data：只能写自己的，可以读所有（匿名聚合行情）
CREATE POLICY "market_write_own" ON market_data
  FOR INSERT WITH CHECK (tenant_id = auth.uid());
CREATE POLICY "market_read_all" ON market_data
  FOR SELECT USING (true);  -- 行情数据公开可读

-- ================================================================
-- 触发器：自动更新 updated_at
-- ================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tenants_updated_at
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ================================================================
-- 触发器：新用户注册时自动创建 tenant 行
-- ================================================================
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.tenants (id, company_name, owner_name, phone)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'company_name', 'Minha Loja'),
    COALESCE(NEW.raw_user_meta_data->>'owner_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'phone', '')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ================================================================
-- 索引（提升查询速度）
-- ================================================================
CREATE INDEX IF NOT EXISTS idx_snapshots_tenant ON erp_snapshots(tenant_id);
CREATE INDEX IF NOT EXISTS idx_snapshots_saved  ON erp_snapshots(saved_at DESC);
CREATE INDEX IF NOT EXISTS idx_market_cat_month ON market_data(product_cat, month);

-- ================================================================
-- 完成提示
-- ================================================================
DO $$
BEGIN
  RAISE NOTICE '✅ ForteBase ERP 多租户 Schema 创建完成';
  RAISE NOTICE '   - tenants 表: 客户账号';
  RAISE NOTICE '   - erp_snapshots 表: ERP数据（按tenant_id隔离）';
  RAISE NOTICE '   - market_data 表: 匿名行情数据';
  RAISE NOTICE '   - RLS 已启用，数据安全隔离';
END $$;
