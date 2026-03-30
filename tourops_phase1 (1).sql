-- ============================================================
-- TourOps Phase 1 — Supabase 完全セットアップSQL
-- 実行方法: Supabase Dashboard > SQL Editor にこれを全選択して貼り付け > Run
-- 順番通りに実行されます。すべて1回の実行でOKです。
-- ============================================================


-- ============================================================
-- STEP 1: 拡張機能の有効化
-- ============================================================

-- UUID自動生成を使えるようにする
create extension if not exists "uuid-ossp";

-- 暗号化ハッシュ関数（パスワード管理等で使用）
create extension if not exists "pgcrypto";


-- ============================================================
-- STEP 2: テナント（契約企業）テーブル
-- 外販SaaS時に複数企業が使う前提の設計
-- フェーズ1では自社（See Jay）の1テナントのみ
-- ============================================================

create table if not exists public.tenants (
  id            uuid primary key default uuid_generate_v4(),
  name          text not null,                        -- 会社名
  plan          text not null default 'starter',      -- starter / pro / enterprise
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.tenants is 'テナント（契約企業）マスタ。フェーズ1はSee Jay1社のみ。';

-- See Jay のテナントレコードを挿入
insert into public.tenants (id, name, plan)
values ('00000000-0000-0000-0000-000000000001', 'See Jay株式会社', 'pro')
on conflict (id) do nothing;


-- ============================================================
-- STEP 3: ユーザー（スタッフ）テーブル
-- Supabase Authと連携。auth.usersと紐付ける
-- ============================================================

create table if not exists public.users (
  id            uuid primary key references auth.users(id) on delete cascade,
  tenant_id     uuid not null references public.tenants(id),
  name          text not null,                        -- 表示名
  email         text not null,
  role          text not null default 'ops',          -- owner / admin / ops / sales / guide
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.users is 'スタッフ・ユーザー管理。auth.usersと1対1で紐付く。';
comment on column public.users.role is 'owner=代表 / admin=管理者 / ops=オペレーター / sales=営業 / guide=ガイド';

-- インデックス
create index if not exists users_tenant_id_idx on public.users(tenant_id);
create index if not exists users_role_idx on public.users(role);


-- ============================================================
-- STEP 4: ガイド（guides）テーブル
-- ============================================================

create table if not exists public.guides (
  id                  uuid primary key default uuid_generate_v4(),
  tenant_id           uuid not null references public.tenants(id),
  name                text not null,                  -- ガイド名
  name_en             text,                           -- 英語名
  email               text,
  phone               text,
  status              text not null default 'active', -- active / training / inactive
  employment_type     text not null default 'freelance', -- employee / freelance / spot
  license_type        text,                           -- 全国通訳案内士 / 地域通訳案内士 / なし
  languages           text[] default '{}',            -- 対応言語: ['英語','日本語'] など
  areas               text[] default '{}',            -- 対応エリア: ['東京','京都'] など
  -- フェーズ1では手入力。フェーズ3でConnecteam連携
  monthly_available_days integer default 20,          -- 月間稼働可能日数
  hourly_rate         integer,                        -- 時給（円）
  daily_rate          integer,                        -- 日当（円）
  -- v2.0 OTA/地図対応（先行設計）
  lat                 numeric(10, 7),                 -- 居住地の緯度（将来の地図表示用）
  lng                 numeric(10, 7),                 -- 居住地の経度
  notes               text,                           -- 備考・特記事項
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.users(id)
);

comment on table public.guides is 'ガイドマスタ。フェーズ3でConnecteam APIと連携予定。';

-- インデックス
create index if not exists guides_tenant_id_idx on public.guides(tenant_id);
create index if not exists guides_status_idx on public.guides(tenant_id, status);


-- ============================================================
-- STEP 5: 取引先（partners）テーブル
-- 旅行会社・法人顧客のマスタ
-- ============================================================

create table if not exists public.partners (
  id                  uuid primary key default uuid_generate_v4(),
  tenant_id           uuid not null references public.tenants(id),
  company_name        text not null,                  -- 会社名
  company_name_en     text,                           -- 英語社名
  country             text,                           -- 国
  region              text,                           -- 地域・州
  status              text not null default 'active', -- active / dormant / prospect / new
  partner_type        text default 'travel_agency',   -- travel_agency / dmc / individual / other
  website             text,
  -- v2.0 法人ネットワーク対応（先行設計）
  -- 担当者は将来テーブル分離。今はJSONBで保持
  contact_persons     jsonb default '[]',
  -- 例: [{"name":"田中","role":"担当","email":"t@x.com","phone":"090-...","note":""}]
  -- v2.0 地図対応（先行設計）
  lat                 numeric(10, 7),
  lng                 numeric(10, 7),
  notes               text,
  first_order_date    date,                           -- 初回取引日（自動更新）
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.users(id)
);

comment on table public.partners is '取引先（旅行会社等）マスタ。contact_personsはPh3でテーブル分離予定。';

-- インデックス
create index if not exists partners_tenant_id_idx on public.partners(tenant_id);
create index if not exists partners_status_idx on public.partners(tenant_id, status);
create index if not exists partners_country_idx on public.partners(tenant_id, country);


-- ============================================================
-- STEP 6: OTAチャンネルマスタ（先行設計・フェーズ2から利用）
-- フェーズ1のスキーマに含める理由:
-- sales_recordsにota_channel_idを付けるので今から必要
-- ============================================================

create table if not exists public.ota_channels (
  id                  uuid primary key default uuid_generate_v4(),
  name                text not null unique,           -- Viator / GetYourGuide / Klook など
  name_short          text,                           -- viator / gyg / klook
  commission_rate     numeric(5, 2),                  -- 手数料率（%）
  api_available       boolean default false,          -- API連携可否
  notes               text,
  created_at          timestamptz not null default now()
);

comment on table public.ota_channels is 'OTAマスタ。フェーズ2から利用。sales_recordsのFK用にフェーズ1で先行作成。';

-- 初期データ投入
insert into public.ota_channels (name, name_short, commission_rate, api_available) values
  ('Viator',          'viator', 20.0, true),
  ('GetYourGuide',    'gyg',    20.0, true),
  ('Klook',           'klook',  20.0, true),
  ('TripAdvisor',     'ta',     null, true),
  ('自社サイト直販',  'direct', 0.0,  false),
  ('旅行会社直接',    'b2b',    0.0,  false)
on conflict (name) do nothing;


-- ============================================================
-- STEP 7: 売上台帳（sales_records）テーブル
-- TourOpsの最重要テーブル。全KPIのデータソース
-- ============================================================

create table if not exists public.sales_records (
  id                  uuid primary key default uuid_generate_v4(),
  tenant_id           uuid not null references public.tenants(id),

  -- 基本情報
  tour_date           date not null,                  -- ツアー実施日
  partner_id          uuid references public.partners(id),  -- 取引先（NULLなら直販）
  tour_name           text not null,                  -- 案件名・ツアー名
  pax                 integer default 1,              -- 参加人数

  -- 売上・費用
  revenue             integer not null,               -- ツアー売上金額（円・税込）
  main_guide_id       uuid references public.guides(id),   -- メインガイド
  sub_guide_ids       uuid[] default '{}',            -- サブガイド（複数対応）
  work_hours          numeric(5, 2),                  -- 労働時間（h）
  guide_fee           integer default 0,              -- ガイド給料合計（円）
  other_costs         integer default 0,              -- その他直接費用（交通費等）

  -- 粗利（自動計算カラム）
  gross_profit        integer generated always as (revenue - guide_fee - other_costs) stored,
  gross_margin        numeric(5, 2) generated always as (
    case when revenue > 0
      then round(((revenue - guide_fee - other_costs)::numeric / revenue * 100), 2)
      else 0
    end
  ) stored,

  -- 入金管理
  invoice_date        date,                           -- 請求日
  payment_due_date    date,                           -- 支払期限
  payment_date        date,                           -- 実際の入金日（NULLなら未収）
  payment_method      text,                           -- bank / card / cash / wise / other
  -- payment_statusはトリガーで自動更新（current_dateはgenerated列に使えないため）
  payment_status      text not null default 'unpaid', -- paid/overdue/pending/unpaid

  -- OTA情報（v2.0先行設計）
  ota_channel_id      uuid references public.ota_channels(id), -- どのOTA経由か
  ota_order_id        text,                           -- OTA側の注文ID

  -- 地理情報（v2.0先行設計）
  tour_area           text,                           -- ツアー実施エリア（東京・京都等）
  lat                 numeric(10, 7),
  lng                 numeric(10, 7),

  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.users(id)
);

comment on table public.sales_records is '売上台帳。TourOpsの中心テーブル。gross_profit・gross_margin・payment_statusは自動計算。';
comment on column public.sales_records.payment_status is 'paid=入金済 / overdue=期日超過 / pending=期日前未収 / unpaid=期日未設定';

-- インデックス（よく使う検索・集計を高速化）
create index if not exists sr_tenant_date_idx    on public.sales_records(tenant_id, tour_date desc);
create index if not exists sr_partner_idx        on public.sales_records(tenant_id, partner_id);
create index if not exists sr_guide_idx          on public.sales_records(tenant_id, main_guide_id);
create index if not exists sr_payment_status_idx on public.sales_records(tenant_id, payment_status);
create index if not exists sr_ota_idx            on public.sales_records(tenant_id, ota_channel_id);


-- ============================================================
-- STEP 8: レビュー台帳（review_records）テーブル
-- ============================================================

create table if not exists public.review_records (
  id                  uuid primary key default uuid_generate_v4(),
  tenant_id           uuid not null references public.tenants(id),

  -- 基本情報
  tour_date           date not null,                  -- ツアー実施日
  review_date         date,                           -- レビュー記入日
  guide_id            uuid not null references public.guides(id),
  sales_record_id     uuid references public.sales_records(id), -- 売上台帳との紐付け

  -- レビュー内容
  reviewer_name       text,                           -- お客様名
  reviewer_country    text,                           -- お客様の国籍
  tour_name           text,                           -- ツアー名
  rating              numeric(3, 1),                  -- 評価（例: 4.5）
  review_text         text,                           -- レビュー本文
  review_url          text,                           -- レビューへのリンク

  -- OTA情報（v2.0先行設計）
  ota_source          text,                           -- viator / gyg / klook / google / direct
  ota_review_id       text,                           -- OTA側のレビューID（重複防止）

  -- 内部メモ
  guide_response      text,                           -- ガイドの返信内容（記録用）
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.users(id)
);

comment on table public.review_records is 'レビュー台帳。ota_sourceでどのOTAのレビューかを管理（v2.0先行設計）。';

-- インデックス
create index if not exists rr_tenant_date_idx on public.review_records(tenant_id, tour_date desc);
create index if not exists rr_guide_idx       on public.review_records(tenant_id, guide_id);
create index if not exists rr_ota_idx         on public.review_records(tenant_id, ota_source);


-- ============================================================
-- STEP 9: 法務台帳（legal_contracts）テーブル
-- ============================================================

create table if not exists public.legal_contracts (
  id                    uuid primary key default uuid_generate_v4(),
  tenant_id             uuid not null references public.tenants(id),

  -- 契約相手
  counterparty_type     text not null,                -- partner / guide / vendor / other
  partner_id            uuid references public.partners(id),
  guide_id              uuid references public.guides(id),
  counterparty_name     text,                         -- パートナー・ガイド以外の場合

  -- 契約情報
  contract_type         text not null,                -- nda / agency / employment / other
  contract_title        text not null,                -- 契約書タイトル
  signed_date           date,                         -- 締結日
  effective_date        date,                         -- 効力発生日
  expiry_date           date,                         -- 契約期限（NULLなら無期限）
  auto_renewal          boolean default false,        -- 自動更新有無
  renewal_notice_days   integer default 30,           -- 何日前に更新通知するか

  -- statusはトリガーで自動更新（current_dateはgenerated列に使えないため）
  status                text not null default 'active', -- active/expired/expiring_soon

  -- ファイル（フェーズ2でSupabase Storage連携）
  file_path             text,                         -- Supabase Storage のパス
  file_url              text,                         -- 署名付きURL（期限付き）

  -- リスク管理
  risk_level            text default 'low',           -- low / medium / high
  risk_notes            text,                         -- リスクメモ（機密。owner/adminのみ閲覧）

  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid references public.users(id),
  updated_by            uuid references public.users(id)
);

comment on table public.legal_contracts is '法務台帳。statusは自動計算。risk_notesはowner/adminのみ閲覧可能（RLSで制御）。';
comment on column public.legal_contracts.status is 'active=有効 / expired=期限切れ / expiring_soon=30日以内に期限';

-- インデックス
create index if not exists lc_tenant_idx      on public.legal_contracts(tenant_id);
create index if not exists lc_status_idx      on public.legal_contracts(tenant_id, status);
create index if not exists lc_expiry_idx      on public.legal_contracts(tenant_id, expiry_date);
create index if not exists lc_partner_idx     on public.legal_contracts(tenant_id, partner_id);
create index if not exists lc_guide_idx       on public.legal_contracts(tenant_id, guide_id);


-- ============================================================
-- STEP 10: 監査ログ（audit_logs）テーブル
-- 全テーブルの操作を自動記録。改ざん不可設計
-- ============================================================

create table if not exists public.audit_logs (
  id            bigserial primary key,               -- 連番（UUIDより高速）
  tenant_id     uuid,
  user_id       uuid,
  action        text not null,                       -- INSERT / UPDATE / DELETE
  table_name    text not null,
  record_id     uuid,
  old_data      jsonb,                               -- 変更前のデータ
  new_data      jsonb,                               -- 変更後のデータ
  ip_address    inet,
  created_at    timestamptz not null default now()
);

comment on table public.audit_logs is '全テーブル操作の監査ログ。削除・更新不可（RLSで制御）。';

-- インデックス（時系列検索・テナント別検索を高速化）
create index if not exists al_tenant_idx      on public.audit_logs(tenant_id, created_at desc);
create index if not exists al_table_idx       on public.audit_logs(table_name, created_at desc);
create index if not exists al_user_idx        on public.audit_logs(user_id, created_at desc);


-- ============================================================
-- STEP 11: KPI目標管理テーブル（フェーズ2から利用・先行作成）
-- ============================================================

create table if not exists public.kpi_targets (
  id                  uuid primary key default uuid_generate_v4(),
  tenant_id           uuid not null references public.tenants(id),
  target_month        date not null,                  -- 対象月（例: 2026-04-01）
  revenue_target      integer,                        -- 売上目標（円）
  gross_profit_target integer,                        -- 粗利目標（円）
  tour_count_target   integer,                        -- 件数目標
  review_count_target integer,                        -- レビュー獲得目標数
  new_partner_target  integer,                        -- 新規パートナー目標数
  guide_count_target  integer,                        -- 稼働ガイド目標数
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.users(id),
  unique(tenant_id, target_month)
);

comment on table public.kpi_targets is 'KPI月次目標値。フェーズ2のダッシュボード比較機能で利用。';


-- ============================================================
-- STEP 12: updated_at 自動更新トリガー
-- レコードが更新されると updated_at が自動で現在時刻に更新される
-- ============================================================

create or replace function public.handle_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- 各テーブルにトリガーを設定
create trigger set_updated_at before update on public.tenants
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.users
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.guides
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.partners
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.sales_records
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.review_records
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.legal_contracts
  for each row execute function public.handle_updated_at();

create trigger set_updated_at before update on public.kpi_targets
  for each row execute function public.handle_updated_at();


-- ============================================================
-- STEP 13: 監査ログ自動記録トリガー
-- INSERT / UPDATE / DELETE があると audit_logs に自動記録
-- ============================================================

create or replace function public.handle_audit_log()
returns trigger language plpgsql security definer as $$
declare
  v_user_id  uuid;
  v_tenant_id uuid;
  v_record_id uuid;
begin
  -- 現在のユーザーIDを取得
  begin
    v_user_id := auth.uid();
  exception when others then
    v_user_id := null;
  end;

  -- tenant_idとrecord_idを取得
  if TG_OP = 'DELETE' then
    begin v_tenant_id := old.tenant_id; exception when others then null; end;
    begin v_record_id := old.id;        exception when others then null; end;
  else
    begin v_tenant_id := new.tenant_id; exception when others then null; end;
    begin v_record_id := new.id;        exception when others then null; end;
  end if;

  insert into public.audit_logs (
    tenant_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    v_tenant_id,
    v_user_id,
    TG_OP,
    TG_TABLE_NAME,
    v_record_id,
    case when TG_OP in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('INSERT','UPDATE') then to_jsonb(new) else null end
  );

  if TG_OP = 'DELETE' then return old; else return new; end if;
end;
$$;

-- 重要テーブルに監査ログトリガーを設定
create trigger audit_sales_records
  after insert or update or delete on public.sales_records
  for each row execute function public.handle_audit_log();

create trigger audit_legal_contracts
  after insert or update or delete on public.legal_contracts
  for each row execute function public.handle_audit_log();

create trigger audit_guides
  after insert or update or delete on public.guides
  for each row execute function public.handle_audit_log();

create trigger audit_partners
  after insert or update or delete on public.partners
  for each row execute function public.handle_audit_log();


-- ============================================================
-- STEP 14: partners の first_order_date 自動更新トリガー
-- 最初の売上が入ったとき、パートナーの初回取引日を自動セット
-- ============================================================

create or replace function public.handle_first_order_date()
returns trigger language plpgsql as $$
begin
  if new.partner_id is not null then
    update public.partners
    set first_order_date = new.tour_date
    where id = new.partner_id
      and (first_order_date is null or first_order_date > new.tour_date);
  end if;
  return new;
end;
$$;

create trigger set_first_order_date
  after insert on public.sales_records
  for each row execute function public.handle_first_order_date();


-- ============================================================
-- STEP 14b: payment_status 自動更新トリガー
-- INSERT/UPDATE時に payment_date・payment_due_date から自動判定
-- ============================================================

create or replace function public.handle_payment_status()
returns trigger language plpgsql as $$
begin
  new.payment_status :=
    case
      when new.payment_date is not null                                        then 'paid'
      when new.payment_due_date is not null and new.payment_due_date < current_date then 'overdue'
      when new.payment_due_date is not null                                    then 'pending'
      else 'unpaid'
    end;
  return new;
end;
$$;

create trigger set_payment_status
  before insert or update on public.sales_records
  for each row execute function public.handle_payment_status();


-- ============================================================
-- STEP 14c: contract status 自動更新トリガー
-- INSERT/UPDATE時に expiry_date から自動判定
-- また毎日バッチで全件再計算するためのSQL関数も定義
-- ============================================================

create or replace function public.handle_contract_status()
returns trigger language plpgsql as $$
begin
  new.status :=
    case
      when new.expiry_date is null                                          then 'active'
      when new.expiry_date < current_date                                   then 'expired'
      when new.expiry_date <= current_date + interval '30 days'             then 'expiring_soon'
      else 'active'
    end;
  return new;
end;
$$;

create trigger set_contract_status
  before insert or update on public.legal_contracts
  for each row execute function public.handle_contract_status();

-- 毎日contract statusを最新化するバッチ関数（Supabase Cron等から呼ぶ）
create or replace function public.refresh_contract_statuses()
returns void language plpgsql as $$
begin
  update public.legal_contracts set updated_at = updated_at; -- トリガーを再発火させる
end;
$$;

-- 毎日sales_recordsのoverdue判定を最新化するバッチ関数
create or replace function public.refresh_payment_statuses()
returns void language plpgsql as $$
begin
  update public.sales_records
  set payment_status =
    case
      when payment_date is not null                                        then 'paid'
      when payment_due_date is not null and payment_due_date < current_date then 'overdue'
      when payment_due_date is not null                                    then 'pending'
      else 'unpaid'
    end
  where payment_status != 'paid';  -- 入金済みは変更不要なので除外（高速化）
end;
$$;


-- ============================================================
-- STEP 15: Row Level Security（RLS）の設定
-- 「誰がどのデータを見られるか」をDB側で強制する
-- これがないと誰でも全データにアクセスできてしまう
-- ============================================================

-- RLSを有効化
alter table public.tenants         enable row level security;
alter table public.users           enable row level security;
alter table public.guides          enable row level security;
alter table public.partners        enable row level security;
alter table public.ota_channels    enable row level security;
alter table public.sales_records   enable row level security;
alter table public.review_records  enable row level security;
alter table public.legal_contracts enable row level security;
alter table public.audit_logs      enable row level security;
alter table public.kpi_targets     enable row level security;

-- ────────────────────────────────
-- 補助関数：現在のユーザーのtenant_idを取得
-- ────────────────────────────────
create or replace function public.my_tenant_id()
returns uuid language sql stable security definer as $$
  select tenant_id from public.users where id = auth.uid() limit 1;
$$;

-- 補助関数：現在のユーザーのroleを取得
create or replace function public.my_role()
returns text language sql stable security definer as $$
  select role from public.users where id = auth.uid() limit 1;
$$;


-- ────────────────────────────────
-- tenants テーブルのRLS
-- ────────────────────────────────
create policy "自分のテナントのみ閲覧" on public.tenants
  for select using (id = public.my_tenant_id());

-- ownerのみテナント情報を更新可能
create policy "ownerのみ更新" on public.tenants
  for update using (id = public.my_tenant_id() and public.my_role() = 'owner');


-- ────────────────────────────────
-- users テーブルのRLS
-- ────────────────────────────────
create policy "同一テナントのユーザーを閲覧" on public.users
  for select using (tenant_id = public.my_tenant_id());

create policy "owner/adminのみユーザー管理" on public.users
  for all using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );

-- 自分自身のプロフィールは更新可能
create policy "自分のプロフィールを更新" on public.users
  for update using (id = auth.uid());


-- ────────────────────────────────
-- guides テーブルのRLS
-- ────────────────────────────────
create policy "ガイド閲覧：同一テナント" on public.guides
  for select using (tenant_id = public.my_tenant_id());

create policy "ガイド編集：owner/admin/ops" on public.guides
  for insert with check (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

create policy "ガイド更新：owner/admin/ops" on public.guides
  for update using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

create policy "ガイド削除：owner/adminのみ" on public.guides
  for delete using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );


-- ────────────────────────────────
-- partners テーブルのRLS
-- ────────────────────────────────
create policy "取引先閲覧：同一テナント" on public.partners
  for select using (tenant_id = public.my_tenant_id());

create policy "取引先編集：owner/admin/ops/sales" on public.partners
  for insert with check (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops', 'sales')
  );

create policy "取引先更新：owner/admin/ops/sales" on public.partners
  for update using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops', 'sales')
  );

create policy "取引先削除：owner/adminのみ" on public.partners
  for delete using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );


-- ────────────────────────────────
-- ota_channels テーブルのRLS
-- （マスタデータ。全テナントが閲覧可能）
-- ────────────────────────────────
create policy "OTAマスタ全員閲覧" on public.ota_channels
  for select using (true);

create policy "OTAマスタ編集：ownerのみ" on public.ota_channels
  for all using (public.my_role() = 'owner');


-- ────────────────────────────────
-- sales_records テーブルのRLS
-- ────────────────────────────────
create policy "売上台帳閲覧：owner/admin/ops" on public.sales_records
  for select using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

-- salesロールは閲覧のみ（金額詳細は見えない。将来的にビューで制御）
create policy "売上台帳閲覧：sales（件数のみ）" on public.sales_records
  for select using (
    tenant_id = public.my_tenant_id()
    and public.my_role() = 'sales'
  );

create policy "売上台帳作成：owner/admin/ops" on public.sales_records
  for insert with check (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

create policy "売上台帳更新：owner/admin/ops" on public.sales_records
  for update using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

create policy "売上台帳削除：owner/adminのみ" on public.sales_records
  for delete using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );


-- ────────────────────────────────
-- review_records テーブルのRLS
-- ────────────────────────────────
create policy "レビュー閲覧：同一テナント（guideは自分のみ）" on public.review_records
  for select using (
    tenant_id = public.my_tenant_id()
    and (
      public.my_role() in ('owner', 'admin', 'ops', 'sales')
      -- guideロールは自分のレビューのみ
      or (public.my_role() = 'guide'
          and guide_id = (select id from public.guides where id = auth.uid() limit 1))
    )
  );

create policy "レビュー作成：owner/admin/ops" on public.review_records
  for insert with check (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

create policy "レビュー更新：owner/admin/ops" on public.review_records
  for update using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin', 'ops')
  );

create policy "レビュー削除：owner/adminのみ" on public.review_records
  for delete using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );


-- ────────────────────────────────
-- legal_contracts テーブルのRLS
-- 法務データは owner/admin のみ
-- ────────────────────────────────
create policy "法務閲覧：owner/adminのみ" on public.legal_contracts
  for select using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );

create policy "法務作成：owner/adminのみ" on public.legal_contracts
  for insert with check (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );

create policy "法務更新：owner/adminのみ" on public.legal_contracts
  for update using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );

create policy "法務削除：ownerのみ" on public.legal_contracts
  for delete using (
    tenant_id = public.my_tenant_id()
    and public.my_role() = 'owner'
  );


-- ────────────────────────────────
-- audit_logs テーブルのRLS
-- 監査ログは閲覧のみ。削除・更新は誰もできない
-- ────────────────────────────────
create policy "監査ログ閲覧：owner/adminのみ" on public.audit_logs
  for select using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );
-- INSERT はトリガー（security definer）経由のみ → ポリシー不要
-- UPDATE / DELETE は誰にも許可しない（ポリシーなし = 全員拒否）


-- ────────────────────────────────
-- kpi_targets テーブルのRLS
-- ────────────────────────────────
create policy "KPI目標閲覧：同一テナント" on public.kpi_targets
  for select using (tenant_id = public.my_tenant_id());

create policy "KPI目標設定：owner/adminのみ" on public.kpi_targets
  for all using (
    tenant_id = public.my_tenant_id()
    and public.my_role() in ('owner', 'admin')
  );


-- ============================================================
-- STEP 16: よく使うビュー（集計クエリを簡単にするため）
-- ============================================================

-- 月次売上サマリービュー（ダッシュボード用）
create or replace view public.v_monthly_summary as
select
  tenant_id,
  date_trunc('month', tour_date)::date                          as month,
  count(*)                                                      as tour_count,
  sum(revenue)                                                  as total_revenue,
  sum(guide_fee)                                                as total_guide_fee,
  sum(gross_profit)                                             as total_gross_profit,
  round(sum(gross_profit)::numeric / nullif(sum(revenue), 0) * 100, 1) as gross_margin_pct,
  count(distinct main_guide_id)                                 as active_guide_count,
  count(distinct partner_id)                                    as active_partner_count,
  round(sum(revenue)::numeric / nullif(count(*), 0), 0)        as avg_tour_price,
  count(*) filter (where payment_status = 'paid')               as paid_count,
  count(*) filter (where payment_status != 'paid')              as unpaid_count,
  sum(revenue) filter (where payment_status = 'paid')           as paid_revenue,
  sum(revenue) filter (where payment_status != 'paid')          as unpaid_revenue
from public.sales_records
group by tenant_id, date_trunc('month', tour_date);

comment on view public.v_monthly_summary is '月次売上サマリー。ダッシュボードのグラフ・KPIカードの主要データソース。';


-- ガイド別パフォーマンスビュー
-- サブクエリではなくLEFT JOINで集計することでエラーを回避
create or replace view public.v_guide_performance as
with tour_agg as (
  -- ガイド×月ごとのツアー集計
  select
    sr.tenant_id,
    date_trunc('month', sr.tour_date)::date as month,
    sr.main_guide_id                        as guide_id,
    count(*)                                as tour_count,
    sum(sr.revenue)                         as total_revenue,
    sum(sr.guide_fee)                       as total_fee
  from public.sales_records sr
  where sr.main_guide_id is not null
  group by sr.tenant_id, date_trunc('month', sr.tour_date), sr.main_guide_id
),
review_agg as (
  -- ガイド×月ごとのレビュー集計
  select
    rr.tenant_id,
    date_trunc('month', rr.tour_date)::date as month,
    rr.guide_id,
    count(*)                                as review_count
  from public.review_records rr
  group by rr.tenant_id, date_trunc('month', rr.tour_date), rr.guide_id
)
select
  t.tenant_id,
  t.month,
  t.guide_id,
  g.name                                                        as guide_name,
  t.tour_count,
  t.total_revenue,
  t.total_fee,
  coalesce(r.review_count, 0)                                   as review_count,
  round(
    coalesce(r.review_count, 0)::numeric
      / nullif(t.tour_count, 0) * 100,
    1
  )                                                             as review_rate_pct
from tour_agg t
join public.guides g on g.id = t.guide_id
left join review_agg r
  on r.guide_id  = t.guide_id
 and r.month     = t.month
 and r.tenant_id = t.tenant_id;

comment on view public.v_guide_performance is 'ガイド別月次パフォーマンス。レビュー獲得率の計算を含む。CTEで集計してJOINする方式。';


-- 未収金一覧ビュー（入金管理用）
create or replace view public.v_unpaid_records as
select
  sr.*,
  p.company_name as partner_name,
  g.name         as main_guide_name,
  case
    when sr.payment_due_date is not null
      then (current_date - sr.payment_due_date)
    else null
  end as overdue_days
from public.sales_records sr
left join public.partners p on p.id = sr.partner_id
left join public.guides   g on g.id = sr.main_guide_id
where sr.payment_status in ('unpaid', 'pending', 'overdue')
order by sr.payment_due_date nulls last, sr.tour_date;

comment on view public.v_unpaid_records is '未収金一覧。入金管理ダッシュボードで使用。';


-- 期限が近い契約一覧ビュー（法務アラート用）
create or replace view public.v_expiring_contracts as
select
  lc.*,
  p.company_name as partner_name,
  g.name         as guide_name,
  (lc.expiry_date - current_date) as days_until_expiry
from public.legal_contracts lc
left join public.partners p on p.id = lc.partner_id
left join public.guides   g on g.id = lc.guide_id
where lc.expiry_date is not null
  and lc.expiry_date >= current_date
  and lc.expiry_date <= current_date + interval '90 days'
order by lc.expiry_date;

comment on view public.v_expiring_contracts is '90日以内に期限を迎える契約の一覧。法務ダッシュボードのアラートで使用。';


-- ============================================================
-- STEP 17: 動作確認クエリ
-- 実行後にこれを実行して正常に作成されたか確認してください
-- ============================================================

-- テーブル一覧確認
select table_name, table_type
from information_schema.tables
where table_schema = 'public'
  and table_type in ('BASE TABLE', 'VIEW')
order by table_type, table_name;

/*
-- 以下が表示されれば成功です:
BASE TABLE  audit_logs
BASE TABLE  guides
BASE TABLE  kpi_targets
BASE TABLE  legal_contracts
BASE TABLE  ota_channels
BASE TABLE  partners
BASE TABLE  review_records
BASE TABLE  sales_records
BASE TABLE  tenants
BASE TABLE  users
VIEW        v_expiring_contracts
VIEW        v_guide_performance
VIEW        v_monthly_summary
VIEW        v_unpaid_records
*/


-- ============================================================
-- セットアップ完了！
-- 次のステップ: 
--   1. Supabase Dashboard > Authentication > Users で
--      代表のメールアドレスでユーザーを作成
--   2. 作成されたuser_idをusersテーブルに手動でINSERT
--   3. Next.jsアプリとSupabaseを接続してログイン画面を作成
-- ============================================================
