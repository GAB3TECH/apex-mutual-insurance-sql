-- ============================================================================
-- Apex Mutual Insurance — Analytical SQL Portfolio (PostgreSQL)
-- ============================================================================
-- 10 production-grade business questions. Run in order; each query is
-- self-contained and labelled Q1–Q10.
--
-- Conventions used throughout:
--   * UPPERCASE keywords, explicit column aliases, CTEs instead of nested
--     subqueries, FILTER (WHERE ...) for conditional aggregates.
--   * "Incurred" = SUM(claim_amount_paid) on Approved claims. Pending and
--     Denied claims pay $0 by design (enforced by CHECK constraints), so
--     SUM(claim_amount_paid) over all claims gives the same total — the
--     explicit Approved filter keeps the intent readable.
--   * "Earned / written premium" = SUM(annual_premium) over the policies
--     in the group. Loss ratio = incurred / premium. A ratio above 1.0
--     means the group paid out more than it collected.
--   * Snapshot date is 2025-12-31. Claims filed late in Dec 2025 whose
--     settlement would run past the snapshot are Pending (date_closed NULL).
--
-- Run:  psql -d apex_mutual -f queries/analysis.sql
-- ============================================================================

-- ============================================================================
-- Q1 — CORE METRICS: Loss ratio by policy type
-- Business question: which line of business is actually profitable?
-- Loss ratio = total incurred claims / total premiums. Above ~75% the line
-- needs repricing, tighter underwriting, or both.
-- ============================================================================
WITH premiums AS (
    SELECT
        policy_type,
        COUNT(*)                         AS policy_count,
        SUM(annual_premium)              AS total_premium,
        AVG(annual_premium)              AS avg_annual_premium
    FROM policies
    GROUP BY policy_type
),
incurred AS (
    SELECT
        pol.policy_type,
        COUNT(*)                         AS claim_count,
        COUNT(*) FILTER (WHERE c.status = 'Approved') AS approved_claim_count,
        SUM(c.claim_amount_paid)         AS total_incurred,
        AVG(c.claim_amount_paid) FILTER (WHERE c.status = 'Approved')
                                         AS avg_severity_approved
    FROM claims AS c
    JOIN policies AS pol
        ON pol.policy_id = c.policy_id
    GROUP BY pol.policy_type
)
SELECT
    p.policy_type,
    p.policy_count,
    ROUND(p.total_premium, 2)            AS total_premium,
    ROUND(p.avg_annual_premium, 2)       AS avg_annual_premium,
    i.claim_count,
    ROUND(i.total_incurred, 2)           AS total_incurred,
    ROUND(i.claim_count::NUMERIC / p.policy_count, 2)
                                         AS claims_per_policy,
    ROUND(i.avg_severity_approved, 2)    AS avg_severity_approved,
    ROUND(i.total_incurred / p.total_premium, 4)
                                         AS loss_ratio,
    -- Combined-ratio proxy: loss ratio + a 28% expense assumption.
    -- 28% is an assumption for this synthetic book, not a measured cost.
    ROUND(i.total_incurred / p.total_premium + 0.28, 4)
                                         AS combined_ratio_proxy
FROM premiums AS p
JOIN incurred AS i
    ON i.policy_type = p.policy_type
ORDER BY loss_ratio DESC;

-- ============================================================================
-- Q2 — WINDOW FUNCTIONS: Rolling 90-day claims volume and running
--      cumulative claims paid, by region (policyholder state)
-- Business question: is claims volume building in a region, or was last
-- month a one-off? A 90-day rolling window smooths weekly noise; the
-- running total shows how fast paid losses accumulate through the year.
-- Method: a daily spine per state (so a quiet day counts as 0, not as a
-- missing row), then a 90-row window = 90 days on a complete daily spine.
-- Output is sampled to the 1st of each month to keep it readable.
-- ============================================================================
WITH spine AS (
    SELECT claim_date
    FROM GENERATE_SERIES(DATE '2023-01-01', DATE '2025-12-31', INTERVAL '1 day')
        AS d (claim_date)
),
states AS (
    SELECT DISTINCT state FROM policyholders
),
claims_with_state AS (
    -- One row per claim, tagged with the policyholder's state, so the
    -- LEFT JOIN below cannot count the same claim once per state.
    SELECT
        c.claim_id,
        c.date_filed,
        c.claim_amount_paid,
        ph.state
    FROM claims AS c
    JOIN policies AS pol
        ON pol.policy_id = c.policy_id
    JOIN policyholders AS ph
        ON ph.policyholder_id = pol.policyholder_id
),
daily AS (
    SELECT
        s.claim_date,
        st.state,
        COUNT(cs.claim_id)               AS claims_filed,
        COALESCE(SUM(cs.claim_amount_paid), 0) AS paid_that_day
    FROM spine AS s
    CROSS JOIN states AS st
    LEFT JOIN claims_with_state AS cs
        ON cs.state = st.state
        AND cs.date_filed = s.claim_date
    GROUP BY s.claim_date, st.state
),
windowed AS (
    SELECT
        claim_date,
        state,
        claims_filed,
        paid_that_day,
        SUM(claims_filed) OVER (
            PARTITION BY state
            ORDER BY claim_date
            ROWS BETWEEN 89 PRECEDING AND CURRENT ROW
        )                                AS rolling_90d_claims,
        SUM(paid_that_day) OVER (
            PARTITION BY state
            ORDER BY claim_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                AS running_cumulative_paid
    FROM daily
)
SELECT
    claim_date,
    state,
    claims_filed,
    rolling_90d_claims,
    ROUND(running_cumulative_paid, 2)    AS running_cumulative_paid
FROM windowed
WHERE EXTRACT(DAY FROM claim_date) = 1
ORDER BY state, claim_date;

-- ============================================================================
-- Q3 — CUSTOMER SEGMENTATION & CHURN: Cohort retention and lapse rates
--      by age band and credit band
-- Business question: who lapses? If young, low-credit holders churn at
-- twice the rate of older, high-credit holders, retention spend should
-- follow that split — not a blanket discount.
-- Cohort = policyholder signup year. Age is measured at the snapshot
-- date (2025-12-31). A policy counts as retained only while Active.
-- ============================================================================
WITH holder_age AS (
    SELECT
        policyholder_id,
        credit_score_band,
        EXTRACT(YEAR FROM signup_date)   AS signup_cohort,
        EXTRACT(YEAR FROM AGE(DATE '2025-12-31', date_of_birth)) AS age_years
    FROM policyholders
),
cohort_policies AS (
    SELECT
        ha.signup_cohort,
        CASE
            WHEN ha.age_years < 25 THEN 'Under 25'
            WHEN ha.age_years < 40 THEN '25–39'
            WHEN ha.age_years < 55 THEN '40–54'
            ELSE '55+'
        END                              AS age_band,
        ha.credit_score_band,
        COUNT(*)                         AS policy_count,
        COUNT(*) FILTER (WHERE pol.status = 'Active')
                                         AS active_policies,
        COUNT(*) FILTER (WHERE pol.status = 'Lapsed')
                                         AS lapsed_policies,
        COUNT(*) FILTER (WHERE pol.status = 'Cancelled')
                                         AS cancelled_policies
    FROM holder_age AS ha
    JOIN policies AS pol
        ON pol.policyholder_id = ha.policyholder_id
    GROUP BY ha.signup_cohort, age_band, ha.credit_score_band
)
SELECT
    signup_cohort,
    age_band,
    credit_score_band,
    policy_count,
    active_policies,
    ROUND(active_policies::NUMERIC / policy_count, 4)   AS retention_rate,
    ROUND(lapsed_policies::NUMERIC / policy_count, 4)   AS lapse_rate,
    ROUND(cancelled_policies::NUMERIC / policy_count, 4) AS cancellation_rate
FROM cohort_policies
ORDER BY signup_cohort, age_band, credit_score_band;

-- ============================================================================
-- Q4 — FRAUD & RISK DETECTION: Repeat claimants and anomalous
--      claim-to-premium ratios (CTEs + NTILE / PERCENT_RANK)
-- Business question: which policies look nothing like the rest of the
-- book? A policy that claimed 4x its annual premium, or filed 5 claims
-- in 3 years, earns a Special Investigations Unit review — not an
-- automatic denial.
-- Method: rank every policy by paid-to-premium ratio into deciles
-- (NTILE) and by percentile (PERCENT_RANK). Flag the top decile, the
-- top 5% by percentile, repeat filers (3+ claims), and any fraud flag.
-- ============================================================================
WITH policy_claims AS (
    SELECT
        pol.policy_id,
        pol.policyholder_id,
        pol.policy_type,
        pol.annual_premium,
        COUNT(c.claim_id)                AS claim_count,
        COUNT(*) FILTER (WHERE c.fraud_flag) AS fraud_flag_count,
        COALESCE(SUM(c.claim_amount_paid), 0)   AS total_paid,
        COALESCE(MAX(c.claim_amount_requested), 0) AS largest_single_claim
    FROM policies AS pol
    LEFT JOIN claims AS c
        ON c.policy_id = pol.policy_id
    GROUP BY pol.policy_id, pol.policyholder_id, pol.policy_type, pol.annual_premium
),
ranked AS (
    SELECT
        pc.*,
        ROUND(pc.total_paid / NULLIF(pc.annual_premium, 0), 2)
                                         AS claim_to_premium_ratio,
        NTILE(10) OVER (ORDER BY pc.total_paid / NULLIF(pc.annual_premium, 0) DESC)
                                         AS ratio_decile,
        PERCENT_RANK() OVER (ORDER BY pc.total_paid / NULLIF(pc.annual_premium, 0))
                                         AS ratio_percent_rank
    FROM policy_claims AS pc
    WHERE pc.claim_count > 0
)
SELECT
    r.policy_id,
    ph.first_name || ' ' || ph.last_name AS policyholder_name,
    ph.state,
    r.policy_type,
    r.annual_premium,
    r.claim_count,
    r.fraud_flag_count,
    ROUND(r.total_paid, 2)               AS total_paid,
    ROUND(r.largest_single_claim, 2)     AS largest_single_claim,
    r.claim_to_premium_ratio,
    r.ratio_decile,
    ROUND(r.ratio_percent_rank, 3)       AS ratio_percent_rank,
    CASE
        WHEN r.fraud_flag_count > 0 THEN 'Review: fraud flag on file'
        WHEN r.claim_count >= 4 THEN 'Review: repeat filer (4+ claims)'
        WHEN r.ratio_decile = 1 THEN 'Review: top-decile claim-to-premium'
        ELSE 'Watch: elevated ratio'
    END                                  AS review_reason
FROM ranked AS r
JOIN policyholders AS ph
    ON ph.policyholder_id = r.policyholder_id
WHERE r.ratio_decile = 1
   OR r.ratio_percent_rank >= 0.95
   OR r.claim_count >= 3
   OR r.fraud_flag_count > 0
ORDER BY r.claim_to_premium_ratio DESC, r.claim_count DESC
LIMIT 50;

-- ============================================================================
-- Q5 — OPERATIONAL EFFICIENCY: Average settlement cycle time by
--      handling agent and claim severity
-- Business question: who settles fast, and does severity explain the
-- slow ones? A large-loss claim taking 40 days may be normal; a small
-- claim taking 40 days is a process problem.
-- Cycle time = date_closed − date_filed, in days, on closed claims only.
-- ============================================================================
WITH closed_claims AS (
    SELECT
        c.handling_agent_id,
        CASE
            WHEN c.claim_amount_requested < 1000 THEN 'Small (<$1k)'
            WHEN c.claim_amount_requested < 5000 THEN 'Medium ($1k–$5k)'
            ELSE 'Large (>$5k)'
        END                              AS severity_band,
        (c.date_closed - c.date_filed)   AS cycle_days,
        c.claim_amount_requested,
        c.claim_amount_paid
    FROM claims AS c
    WHERE c.status IN ('Approved', 'Denied')
      AND c.date_closed IS NOT NULL
),
agent_stats AS (
    SELECT
        handling_agent_id,
        severity_band,
        COUNT(*)                         AS closed_claims,
        ROUND(AVG(cycle_days), 1)        AS avg_cycle_days,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cycle_days)
                                         AS median_cycle_days,
        COUNT(*) FILTER (WHERE cycle_days <= 14)
                                         AS settled_within_14d,
        COUNT(*) FILTER (WHERE cycle_days > 30)
                                         AS settled_after_30d
    FROM closed_claims
    GROUP BY handling_agent_id, severity_band
)
SELECT
    a.first_name || ' ' || a.last_name  AS handling_agent,
    a.branch,
    s.severity_band,
    s.closed_claims,
    s.avg_cycle_days,
    s.median_cycle_days,
    s.settled_within_14d,
    ROUND(s.settled_within_14d::NUMERIC / s.closed_claims, 3)
                                         AS pct_within_14d,
    s.settled_after_30d,
    ROUND(s.settled_after_30d::NUMERIC / s.closed_claims, 3)
                                         AS pct_after_30d
FROM agent_stats AS s
JOIN agents AS a
    ON a.agent_id = s.handling_agent_id
WHERE s.closed_claims >= 10
ORDER BY s.avg_cycle_days DESC;

-- ============================================================================
-- Q6 — GEOGRAPHIC PERFORMANCE: Loss ratio, frequency, and average
--      premium by state
-- Business question: is the book's worst state a pricing problem, a
-- frequency problem, or a severity problem? The three have different
-- fixes (rate, underwriting, claims handling).
-- ============================================================================
WITH state_premiums AS (
    SELECT
        ph.state,
        COUNT(DISTINCT pol.policy_id)    AS policy_count,
        SUM(pol.annual_premium)          AS total_premium,
        AVG(pol.annual_premium)          AS avg_premium
    FROM policyholders AS ph
    JOIN policies AS pol
        ON pol.policyholder_id = ph.policyholder_id
    GROUP BY ph.state
),
state_claims AS (
    SELECT
        ph.state,
        COUNT(c.claim_id)                AS claim_count,
        COUNT(*) FILTER (WHERE c.status = 'Approved') AS approved_claims,
        SUM(c.claim_amount_paid)         AS total_incurred,
        AVG(c.claim_amount_paid) FILTER (WHERE c.status = 'Approved')
                                         AS avg_severity
    FROM policyholders AS ph
    JOIN policies AS pol
        ON pol.policyholder_id = ph.policyholder_id
    JOIN claims AS c
        ON c.policy_id = pol.policy_id
    GROUP BY ph.state
)
SELECT
    sp.state,
    sp.policy_count,
    ROUND(sp.total_premium, 2)           AS total_premium,
    ROUND(sp.avg_premium, 2)             AS avg_premium,
    sc.claim_count,
    ROUND(sc.claim_count::NUMERIC / sp.policy_count, 2)
                                         AS claims_per_policy,
    ROUND(sc.total_incurred, 2)          AS total_incurred,
    ROUND(sc.avg_severity, 2)            AS avg_severity_approved,
    ROUND(sc.total_incurred / sp.total_premium, 4)
                                         AS loss_ratio
FROM state_premiums AS sp
JOIN state_claims AS sc
    ON sc.state = sp.state
ORDER BY loss_ratio DESC;

-- ============================================================================
-- Q7 — SEASONALITY & TREND: Monthly claims volume, incurred losses,
--      and year-over-year change
-- Business question: when does the book bleed? Winter storm months and
-- late-summer storm months should show up here — if they don't, the
-- seasonal story in the board deck is wrong.
-- ============================================================================
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', c.date_filed) AS claim_month,
        COUNT(*)                         AS claims_filed,
        COUNT(*) FILTER (WHERE c.status = 'Approved') AS approved_claims,
        SUM(c.claim_amount_paid)         AS total_paid,
        AVG(c.claim_amount_paid) FILTER (WHERE c.status = 'Approved')
                                         AS avg_severity
    FROM claims AS c
    GROUP BY DATE_TRUNC('month', c.date_filed)
)
SELECT
    claim_month,
    claims_filed,
    approved_claims,
    ROUND(total_paid, 2)                 AS total_paid,
    ROUND(avg_severity, 2)               AS avg_severity,
    LAG(claims_filed, 12) OVER (ORDER BY claim_month)
                                         AS claims_same_month_last_year,
    ROUND(
        (claims_filed - LAG(claims_filed, 12) OVER (ORDER BY claim_month))::NUMERIC
        / NULLIF(LAG(claims_filed, 12) OVER (ORDER BY claim_month), 0), 4)
                                         AS yoy_claim_growth,
    ROUND(
        AVG(claims_filed) OVER (
            ORDER BY claim_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 1)                            AS rolling_3mo_avg_claims
FROM monthly
ORDER BY claim_month;

-- ============================================================================
-- Q8 — AGENT & BRANCH PERFORMANCE: Premium written, retention, and
--      loss ratio by selling agent
-- Business question: who writes good business, not just a lot of it?
-- An agent with high premium and a 95% loss ratio is growing the wrong
-- book; an agent with modest premium and a 45% loss ratio is the model.
-- Retention here = share of the agent's policies still Active.
-- ============================================================================
WITH agent_book AS (
    SELECT
        pol.agent_id,
        COUNT(*)                         AS policies_written,
        SUM(pol.annual_premium)          AS total_premium,
        COUNT(*) FILTER (WHERE pol.status = 'Active')
                                         AS active_policies
    FROM policies AS pol
    GROUP BY pol.agent_id
),
agent_claims AS (
    SELECT
        pol.agent_id,
        COUNT(c.claim_id)                AS claim_count,
        COALESCE(SUM(c.claim_amount_paid), 0) AS total_incurred,
        COUNT(*) FILTER (WHERE c.fraud_flag) AS fraud_flags
    FROM policies AS pol
    LEFT JOIN claims AS c
        ON c.policy_id = pol.policy_id
    GROUP BY pol.agent_id
)
SELECT
    a.first_name || ' ' || a.last_name  AS agent_name,
    a.branch,
    b.policies_written,
    ROUND(b.total_premium, 2)            AS total_premium,
    ROUND(b.active_policies::NUMERIC / b.policies_written, 3)
                                         AS retention_rate,
    c.claim_count,
    ROUND(c.total_incurred, 2)           AS total_incurred,
    ROUND(c.total_incurred / NULLIF(b.total_premium, 0), 4)
                                         AS loss_ratio,
    c.fraud_flags
FROM agent_book AS b
JOIN agent_claims AS c
    ON c.agent_id = b.agent_id
JOIN agents AS a
    ON a.agent_id = b.agent_id
WHERE b.policies_written >= 30
ORDER BY total_premium DESC;

-- ============================================================================
-- Q9 — UNDERWRITING EFFECTIVENESS: Loss ratio by risk tier, credit band,
--      and prior-claims history
-- Business question: does the risk model actually separate good risks
-- from bad ones? If High-tier and Low-tier loss ratios are the same,
-- the score isn't pricing risk — it's decoration.
-- ============================================================================
WITH underwriting AS (
    SELECT
        r.risk_tier,
        ph.credit_score_band,
        CASE
            WHEN r.prior_claims_3yr = 0 THEN '0 prior claims'
            WHEN r.prior_claims_3yr = 1 THEN '1 prior claim'
            ELSE '2+ prior claims'
        END                              AS prior_claims_bucket,
        COUNT(DISTINCT pol.policy_id)    AS policy_count,
        SUM(pol.annual_premium)          AS total_premium,
        AVG(r.risk_score)                AS avg_risk_score
    FROM policies AS pol
    JOIN underwriting_risk_profiles AS r
        ON r.policy_id = pol.policy_id
    JOIN policyholders AS ph
        ON ph.policyholder_id = pol.policyholder_id
    GROUP BY r.risk_tier, ph.credit_score_band, prior_claims_bucket
),
underwriting_claims AS (
    SELECT
        r.risk_tier,
        ph.credit_score_band,
        CASE
            WHEN r.prior_claims_3yr = 0 THEN '0 prior claims'
            WHEN r.prior_claims_3yr = 1 THEN '1 prior claim'
            ELSE '2+ prior claims'
        END                              AS prior_claims_bucket,
        COUNT(c.claim_id)                AS claim_count,
        COALESCE(SUM(c.claim_amount_paid), 0) AS total_incurred
    FROM policies AS pol
    JOIN underwriting_risk_profiles AS r
        ON r.policy_id = pol.policy_id
    JOIN policyholders AS ph
        ON ph.policyholder_id = pol.policyholder_id
    LEFT JOIN claims AS c
        ON c.policy_id = pol.policy_id
    GROUP BY r.risk_tier, ph.credit_score_band, prior_claims_bucket
)
SELECT
    u.risk_tier,
    u.credit_score_band,
    u.prior_claims_bucket,
    u.policy_count,
    ROUND(u.total_premium, 2)            AS total_premium,
    ROUND(u.avg_risk_score, 1)           AS avg_risk_score,
    uc.claim_count,
    ROUND(uc.claim_count::NUMERIC / u.policy_count, 2)
                                         AS claims_per_policy,
    ROUND(uc.total_incurred, 2)          AS total_incurred,
    ROUND(uc.total_incurred / NULLIF(u.total_premium, 0), 4)
                                         AS loss_ratio
FROM underwriting AS u
JOIN underwriting_claims AS uc
    ON uc.risk_tier = u.risk_tier
    AND uc.credit_score_band = u.credit_score_band
    AND uc.prior_claims_bucket = u.prior_claims_bucket
ORDER BY loss_ratio DESC;

-- ============================================================================
-- Q10 — SEVERITY & DEDUCTIBLES: Claim severity distribution, large-loss
--       concentration, and deductible trade-offs
-- Business question: how much of the loss bill is a handful of big
-- claims, and do higher deductibles actually buy lower frequency?
-- Part A: severity bands — share of claims vs. share of dollars.
-- Part B: deductible bands by policy type — frequency and loss ratio.
-- ============================================================================
-- Part A — severity distribution
WITH severity AS (
    SELECT
        CASE
            WHEN claim_amount_requested < 500 THEN 'Under $500'
            WHEN claim_amount_requested < 1000 THEN '$500–$1k'
            WHEN claim_amount_requested < 5000 THEN '$1k–$5k'
            WHEN claim_amount_requested < 10000 THEN '$5k–$10k'
            ELSE 'Over $10k'
        END                              AS severity_band,
        COUNT(*)                         AS claim_count,
        SUM(claim_amount_requested)      AS total_requested,
        SUM(claim_amount_paid)           AS total_paid
    FROM claims
    GROUP BY severity_band
),
totals AS (
    SELECT
        COUNT(*)                         AS all_claims,
        SUM(claim_amount_paid)           AS all_paid
    FROM claims
)
SELECT
    s.severity_band,
    s.claim_count,
    ROUND(s.claim_count::NUMERIC / t.all_claims, 4)
                                         AS share_of_claims,
    ROUND(s.total_paid, 2)               AS total_paid,
    ROUND(s.total_paid / NULLIF(t.all_paid, 0), 4)
                                         AS share_of_paid_dollars
FROM severity AS s
CROSS JOIN totals AS t
ORDER BY s.total_paid DESC;

-- Part B — deductible trade-off by policy type
WITH deductible_book AS (
    SELECT
        pol.policy_type,
        pol.deductible,
        COUNT(*)                         AS policy_count,
        SUM(pol.annual_premium)          AS total_premium,
        AVG(pol.annual_premium)          AS avg_premium
    FROM policies AS pol
    GROUP BY pol.policy_type, pol.deductible
),
deductible_claims AS (
    SELECT
        pol.policy_type,
        pol.deductible,
        COUNT(c.claim_id)                AS claim_count,
        COALESCE(SUM(c.claim_amount_paid), 0) AS total_incurred
    FROM policies AS pol
    LEFT JOIN claims AS c
        ON c.policy_id = pol.policy_id
    GROUP BY pol.policy_type, pol.deductible
)
SELECT
    b.policy_type,
    b.deductible,
    b.policy_count,
    ROUND(b.avg_premium, 2)              AS avg_premium,
    d.claim_count,
    ROUND(d.claim_count::NUMERIC / b.policy_count, 2)
                                         AS claims_per_policy,
    ROUND(d.total_incurred, 2)           AS total_incurred,
    ROUND(d.total_incurred / NULLIF(b.total_premium, 0), 4)
                                         AS loss_ratio
FROM deductible_book AS b
JOIN deductible_claims AS d
    ON d.policy_type = b.policy_type
    AND d.deductible = b.deductible
ORDER BY b.policy_type, b.deductible;
