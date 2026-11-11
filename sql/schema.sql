-- ============================================================================
-- Apex Mutual Insurance — PostgreSQL schema (3NF)
-- ============================================================================
-- Regional P&C mutual insurer, HQ Hartford, CT.
-- Lines: Auto (55%), Home (30%), Commercial (15%).
-- Footprint: CT, MA, NY, RI, NH, VT.
--
-- Tables (5):
--   policyholders               — one row per customer
--   agents                      — sales / handling agents, by branch
--   policies                    — one row per 12-month policy term
--   underwriting_risk_profiles  — one row per policy (1:1 with policies)
--   claims                      — one row per claim event
--
-- Run:  psql -d apex_mutual -f sql/schema.sql
-- Load: see README.md — \copy each CSV in data/ in dependency order.
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS claims CASCADE;
DROP TABLE IF EXISTS underwriting_risk_profiles CASCADE;
DROP TABLE IF EXISTS policies CASCADE;
DROP TABLE IF EXISTS agents CASCADE;
DROP TABLE IF EXISTS policyholders CASCADE;

-- ----------------------------------------------------------------------------
-- 1. policyholders
-- ----------------------------------------------------------------------------
CREATE TABLE policyholders (
    policyholder_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name        VARCHAR(50)  NOT NULL,
    last_name         VARCHAR(50)  NOT NULL,
    date_of_birth     DATE         NOT NULL,
    gender            CHAR(1)      NOT NULL CHECK (gender IN ('F', 'M')),
    email             VARCHAR(120) NOT NULL UNIQUE,
    phone             VARCHAR(30),
    address           VARCHAR(150) NOT NULL,
    city              VARCHAR(80)  NOT NULL,
    state             CHAR(2)      NOT NULL CHECK (state IN ('CT','MA','NY','RI','NH','VT')),
    zip_code          VARCHAR(10)  NOT NULL,
    credit_score_band VARCHAR(20)  NOT NULL CHECK (credit_score_band IN ('Excellent','Good','Fair','Poor')),
    customer_tier     VARCHAR(20)  NOT NULL CHECK (customer_tier IN ('Preferred','Standard','Non-Standard')),
    signup_date       DATE         NOT NULL,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CHECK (signup_date >= date_of_birth + INTERVAL '16 years'),
    CHECK (signup_date <= CURRENT_DATE)
);

-- ----------------------------------------------------------------------------
-- 2. agents
-- ----------------------------------------------------------------------------
CREATE TABLE agents (
    agent_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name     VARCHAR(50) NOT NULL,
    last_name      VARCHAR(50) NOT NULL,
    branch         VARCHAR(80) NOT NULL,
    state          CHAR(2)     NOT NULL CHECK (state IN ('CT','MA','NY','RI','NH','VT')),
    hire_date      DATE        NOT NULL,
    license_number VARCHAR(30) NOT NULL UNIQUE,
    is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 3. policies — one 12-month term per row; a holder may hold 1–3 policies
-- ----------------------------------------------------------------------------
CREATE TABLE policies (
    policy_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policyholder_id  INTEGER      NOT NULL REFERENCES policyholders (policyholder_id),
    agent_id         INTEGER      NOT NULL REFERENCES agents (agent_id),
    policy_type      VARCHAR(20)  NOT NULL CHECK (policy_type IN ('Auto','Home','Commercial')),
    coverage_limit   NUMERIC(12,2) NOT NULL CHECK (coverage_limit > 0),
    deductible       NUMERIC(10,2) NOT NULL CHECK (deductible >= 0),
    annual_premium   NUMERIC(10,2) NOT NULL CHECK (annual_premium > 0),
    monthly_premium  NUMERIC(10,2) NOT NULL CHECK (monthly_premium > 0),
    effective_date   DATE         NOT NULL,
    expiration_date  DATE         NOT NULL,
    status           VARCHAR(20)  NOT NULL DEFAULT 'Active'
                     CHECK (status IN ('Active','Lapsed','Cancelled')),
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CHECK (expiration_date > effective_date),
    CHECK (expiration_date <= effective_date + INTERVAL '366 days'),
    CHECK (coverage_limit > deductible),
    -- Monthly premium must reconcile with the annual premium (± $0.10 for rounding).
    CHECK (ABS(monthly_premium * 12 - annual_premium) <= 0.10)
);

-- ----------------------------------------------------------------------------
-- 4. underwriting_risk_profiles — 1:1 with policies
-- ----------------------------------------------------------------------------
CREATE TABLE underwriting_risk_profiles (
    profile_id              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_id               INTEGER NOT NULL UNIQUE REFERENCES policies (policy_id),
    risk_score              INTEGER NOT NULL CHECK (risk_score BETWEEN 300 AND 900),
    risk_tier               VARCHAR(10) NOT NULL CHECK (risk_tier IN ('Low','Medium','High')),
    prior_claims_3yr        INTEGER NOT NULL DEFAULT 0 CHECK (prior_claims_3yr >= 0),
    territory_risk_factor   NUMERIC(4,2) NOT NULL CHECK (territory_risk_factor BETWEEN 0.50 AND 2.00),
    years_insured           INTEGER NOT NULL DEFAULT 0 CHECK (years_insured >= 0),
    has_prior_cancellation  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 5. claims — one row per claim event
-- ----------------------------------------------------------------------------
CREATE TABLE claims (
    claim_id               INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_id              INTEGER NOT NULL REFERENCES policies (policy_id),
    claim_type             VARCHAR(40) NOT NULL,
    date_of_incident       DATE NOT NULL,
    date_filed             DATE NOT NULL,
    date_closed            DATE,
    claim_amount_requested NUMERIC(12,2) NOT NULL CHECK (claim_amount_requested >= 0),
    claim_amount_paid      NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (claim_amount_paid >= 0),
    status                 VARCHAR(20) NOT NULL CHECK (status IN ('Approved','Pending','Denied')),
    fraud_flag             BOOLEAN NOT NULL DEFAULT FALSE,
    fraud_score            NUMERIC(5,1) NOT NULL DEFAULT 0 CHECK (fraud_score BETWEEN 0 AND 100),
    handling_agent_id      INTEGER REFERENCES agents (agent_id),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Business rules enforced in the database, not just in the generator:
    CHECK (date_filed >= date_of_incident),
    CHECK (date_filed <= date_of_incident + INTERVAL '30 days'),
    CHECK (date_closed IS NULL OR date_closed >= date_filed),
    CHECK (claim_amount_paid <= claim_amount_requested),
    CHECK (status <> 'Pending' OR date_closed IS NULL),
    CHECK (status <> 'Pending' OR claim_amount_paid = 0),
    CHECK (status <> 'Denied'  OR claim_amount_paid = 0),
    CHECK (status <> 'Approved' OR claim_amount_paid > 0)
);

-- ----------------------------------------------------------------------------
-- Indexes — the ones the analysis queries actually use
-- ----------------------------------------------------------------------------
CREATE INDEX idx_policyholders_state         ON policyholders (state);
CREATE INDEX idx_policyholders_credit_band   ON policyholders (credit_score_band);
CREATE INDEX idx_policyholders_signup_date   ON policyholders (signup_date);

CREATE INDEX idx_policies_policyholder_id    ON policies (policyholder_id);
CREATE INDEX idx_policies_agent_id           ON policies (agent_id);
CREATE INDEX idx_policies_type_status        ON policies (policy_type, status);
CREATE INDEX idx_policies_effective_date     ON policies (effective_date);

CREATE INDEX idx_risk_profiles_policy_id     ON underwriting_risk_profiles (policy_id);
CREATE INDEX idx_risk_profiles_risk_tier     ON underwriting_risk_profiles (risk_tier);

CREATE INDEX idx_claims_policy_id            ON claims (policy_id);
CREATE INDEX idx_claims_date_filed           ON claims (date_filed);
CREATE INDEX idx_claims_date_of_incident     ON claims (date_of_incident);
CREATE INDEX idx_claims_status               ON claims (status);
CREATE INDEX idx_claims_fraud_flag           ON claims (fraud_flag) WHERE fraud_flag = TRUE;
CREATE INDEX idx_claims_handling_agent_id    ON claims (handling_agent_id);

COMMIT;

-- Quick smoke test after loading (see README):
--   SELECT COUNT(*) FROM policyholders;  -- 1,250
--   SELECT COUNT(*) FROM policies;       -- 1,850
--   SELECT COUNT(*) FROM claims;         -- 3,650
