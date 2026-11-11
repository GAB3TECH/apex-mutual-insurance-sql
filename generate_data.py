"""
Apex Mutual Insurance — synthetic dataset generator
=====================================================
Generates a realistic, statistically plausible P&C insurance dataset:

  * 1,250 policyholders
  * 24 agents (6 Northeast branches)
  * 1,850 policies (Auto 55% / Home 30% / Commercial 15%)
  * 1,850 underwriting risk profiles (one per policy)
  * 3,650 claims, Jan 2023 – Dec 2025 (36 months)

Design targets (checked after every run — see the validation block):
  * Overall loss ratio (paid / written premium) ........ 60–75%
  * Denial rate ......................................... 10–15%
  * Fraud-flag rate ..................................... ~2–3%
  * Seasonal spike: winter (Jan/Feb/Dec) and Sep storms

The data is SYNTHETIC. Claim frequency is intentionally higher than
industry norms so every segment (state x policy type x risk tier) has
enough claims to analyse — the loss ratio, denial rate, seasonality
and fraud patterns are the calibrated, realistic parts. Say so in any
write-up; do not present the frequency as an industry benchmark.

Usage:
    pip install -r requirements.txt
    python generate_data.py            # writes data/*.csv
    python generate_data.py --seed 7   # reproducible variant

PostgreSQL load (after creating the schema in sql/schema.sql):
    \\copy policyholders FROM 'data/policyholders.csv' WITH (FORMAT csv, HEADER true)
    ... (see README.md "How to reproduce" for the full sequence)
"""

from __future__ import annotations

import argparse
import random
from datetime import date, timedelta
from pathlib import Path

import pandas as pd
from faker import Faker

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
N_POLICYHOLDERS = 1_250
N_AGENTS = 24
N_POLICIES = 1_850
N_CLAIMS = 3_650
START_DATE = date(2023, 1, 1)
END_DATE = date(2025, 12, 31)
SNAPSHOT_DATE = date(2025, 12, 31)  # "today" for status / pending logic

OUT_DIR = Path(__file__).resolve().parent / "data"

# State mix — Northeast regional footprint, HQ Hartford, CT.
STATES = {
    "CT": {"weight": 0.28, "cities": ["Hartford", "New Haven", "Stamford", "Bridgeport", "Waterbury"]},
    "MA": {"weight": 0.24, "cities": ["Boston", "Worcester", "Springfield", "Cambridge", "Lowell"]},
    "NY": {"weight": 0.18, "cities": ["Albany", "Buffalo", "Rochester", "Syracuse", "White Plains"]},
    "RI": {"weight": 0.12, "cities": ["Providence", "Warwick", "Cranston", "Pawtucket"]},
    "NH": {"weight": 0.10, "cities": ["Manchester", "Nashua", "Concord", "Dover"]},
    "VT": {"weight": 0.08, "cities": ["Burlington", "Rutland", "Montpelier", "Barre"]},
}

BRANCHES = [
    ("Hartford, CT", "CT"), ("New Haven, CT", "CT"),
    ("Boston, MA", "MA"), ("Providence, RI", "RI"),
    ("Albany, NY", "NY"), ("Manchester, NH", "NH"),
]

CREDIT_BANDS = ["Excellent", "Good", "Fair", "Poor"]
CREDIT_WEIGHTS = [0.28, 0.32, 0.26, 0.14]
# Credit -> premium multiplier and insurance-score centre.
CREDIT_EFFECT = {
    "Excellent": {"premium_mult": 0.88, "score": 790},
    "Good": {"premium_mult": 1.00, "score": 700},
    "Fair": {"premium_mult": 1.15, "score": 640},
    "Poor": {"premium_mult": 1.35, "score": 590},
}

POLICY_TYPES = ["Auto", "Home", "Commercial"]
POLICY_WEIGHTS = [0.55, 0.30, 0.15]

COVERAGE_LIMITS = {
    "Auto": [50_000, 100_000, 250_000, 500_000],
    "Home": [150_000, 250_000, 350_000, 500_000, 750_000],
    "Commercial": [500_000, 1_000_000, 2_000_000],
}
DEDUCTIBLES = {
    "Auto": [250, 500, 1_000],
    "Home": [500, 1_000, 2_500],
    "Commercial": [1_000, 2_500, 5_000],
}
# (mean, sd) of annual premium before credit / risk adjustment.
PREMIUM_PARAMS = {
    "Auto": (2_100, 450),
    "Home": (2_400, 600),
    "Commercial": (8_500, 2_800),
}

CLAIM_TYPES = {
    "Auto": ["Collision", "Liability", "Comprehensive", "Theft"],
    "Home": ["Water Damage", "Wind/Hail", "Fire", "Theft", "Liability"],
    "Commercial": ["Property Damage", "Liability", "Business Interruption"],
}
# Median requested amount per claim type (lognormal, sigma = 1.0 below).
# Calibrated so total paid / total written premium lands at 60–75%.
CLAIM_MEDIAN = {
    "Collision": 950, "Liability": 1_100, "Comprehensive": 320, "Theft": 1_400,
    "Water Damage": 1_400, "Wind/Hail": 1_100, "Fire": 4_500,
    "Property Damage": 2_200, "Business Interruption": 3_000,
}
CLAIM_TYPE_WEIGHTS = {
    "Auto": [0.42, 0.28, 0.22, 0.08],
    "Home": [0.34, 0.30, 0.04, 0.16, 0.16],
    "Commercial": [0.48, 0.34, 0.18],
}

# Per-line calibration, measured after generation (see validation block):
# Home severity/frequency are lower than Auto per dollar of premium, and
# Commercial severity is higher — without these, Home's loss ratio exceeds
# 100% and Commercial's sits near 40%, which would dominate every insight.
# Targets per line: Auto ~70–75%, Home ~60–65%, Commercial ~55–60%.
# (Measured after generation; the incident-first sampling change in Nov 2026
# raised the approved share, so Auto severity was cut from 1.00 to 0.78.)
TYPE_FREQUENCY = {"Auto": 1.00, "Home": 0.70, "Commercial": 1.00}
TYPE_SEVERITY = {"Auto": 0.78, "Home": 0.69, "Commercial": 1.20}
MAX_CLAIMS_PER_POLICY = 8  # keeps repeat claimants realistic (no 18-claim policy)

# Seasonal incident weights by month (1.0 = average). Winter freeze /
# ice and Sep storms spike; spring is the quiet season.
MONTH_WEIGHTS = [1.25, 1.20, 1.00, 0.90, 0.95, 1.00,
                 1.05, 1.10, 1.15, 1.00, 0.95, 1.20]


def random_date(rng: random.Random, start: date, end: date) -> date:
    return start + timedelta(days=rng.randint(0, (end - start).days))


def seasonal_incident_date(rng: random.Random, lo: date, hi: date) -> date:
    """Pick an incident date inside [lo, hi], weighted by MONTH_WEIGHTS.

    Rejection sampling: propose a uniform date in the window, accept with
    probability weight(month) / max(weight). Keeps the incident inside the
    policy term AND inside Jan 2023 – Dec 2025 (earlier versions sampled
    the incident first and clamped it into the term, which pushed a
    visible share of claims into late 2025 / 2026).
    """
    lo = max(lo, START_DATE)
    hi = min(hi, date(2025, 12, 24))  # leave room for filing by Dec 31
    if hi < lo:
        return lo
    span = (hi - lo).days
    for _ in range(50):
        cand = lo + timedelta(days=rng.randint(0, span))
        if rng.random() <= MONTH_WEIGHTS[cand.month - 1] / 1.25:
            return cand
    return lo + timedelta(days=rng.randint(0, span))


def lognormal_amount(rng: random.Random, median: float, sigma: float = 1.0) -> float:
    import math
    return round(math.exp(rng.gauss(math.log(median), sigma)), 2)


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------
def gen_agents(fake: Faker, rng: random.Random) -> pd.DataFrame:
    rows = []
    for agent_id in range(1, N_AGENTS + 1):
        branch, state = BRANCHES[(agent_id - 1) % len(BRANCHES)]
        rows.append({
            "agent_id": agent_id,
            "first_name": fake.first_name(),
            "last_name": fake.last_name(),
            "branch": branch,
            "state": state,
            "hire_date": random_date(rng, date(2015, 1, 1), date(2024, 6, 30)),
            "license_number": f"{state}-{rng.randint(100000, 999999)}",
            "is_active": rng.random() > 0.04,  # 1 of 24 inactive
        })
    return pd.DataFrame(rows)


def gen_policyholders(fake: Faker, rng: random.Random) -> pd.DataFrame:
    state_list = list(STATES.keys())
    state_weights = [STATES[s]["weight"] for s in state_list]
    used_emails: set[str] = set()  # schema has UNIQUE(email); Faker collides
    rows = []
    for ph_id in range(1, N_POLICYHOLDERS + 1):
        state = rng.choices(state_list, weights=state_weights, k=1)[0]
        city = rng.choice(STATES[state]["cities"])
        credit = rng.choices(CREDIT_BANDS, weights=CREDIT_WEIGHTS, k=1)[0]
        # Tier follows credit, with a little noise (no invented precision).
        tier = {"Excellent": "Preferred", "Good": "Preferred",
                "Fair": "Standard", "Poor": "Non-Standard"}[credit]
        if rng.random() < 0.12:
            tier = rng.choice(["Standard", "Preferred", "Non-Standard"])
        dob = random_date(rng, date(1955, 1, 1), date(2006, 12, 31))
        # Signup cannot precede age 18 — the schema enforces
        # signup_date >= date_of_birth + 16 years, and 18 is the
        # realistic floor for holding a policy in your own name.
        earliest_signup = max(date(2020, 1, 1),
                              dob.replace(year=dob.year + 18))
        email = fake.email()
        while email in used_emails:
            email = fake.email()
        used_emails.add(email)
        rows.append({
            "policyholder_id": ph_id,
            "first_name": fake.first_name(),
            "last_name": fake.last_name(),
            "date_of_birth": dob,
            "gender": rng.choice(["F", "M"]),
            "email": email,
            "phone": fake.phone_number(),
            "address": fake.street_address(),
            "city": city,
            "state": state,
            "zip_code": fake.zipcode_in_state(state) if hasattr(fake, "zipcode_in_state") else fake.zipcode(),
            "credit_score_band": credit,
            "customer_tier": tier,
            "signup_date": random_date(rng, earliest_signup, date(2025, 10, 31)),
            "created_at": "2025-12-31 00:00:00",
            "updated_at": "2025-12-31 00:00:00",
        })
    return pd.DataFrame(rows)


def gen_policies(rng: random.Random, holders: pd.DataFrame,
                 agents: pd.DataFrame) -> pd.DataFrame:
    # Policy counts per holder: 60% x1, 32% x2, 8% x3  -> 1,850 total.
    counts = rng.choices([1, 2, 3], weights=[0.60, 0.32, 0.08],
                         k=N_POLICYHOLDERS)
    # Trim / pad to exactly N_POLICIES.
    while sum(counts) > N_POLICIES:
        i = rng.randrange(N_POLICYHOLDERS)
        if counts[i] > 1:
            counts[i] -= 1
    while sum(counts) < N_POLICIES:
        counts[rng.randrange(N_POLICYHOLDERS)] += 1

    holder_credit = dict(zip(holders["policyholder_id"],
                             holders["credit_score_band"]))
    holder_dob = dict(zip(holders["policyholder_id"], holders["date_of_birth"]))
    agent_ids = agents["agent_id"].tolist()
    rows = []
    policy_id = 1
    for holder_id, n in enumerate(counts, start=1):
        for _ in range(n):
            ptype = rng.choices(POLICY_TYPES, weights=POLICY_WEIGHTS, k=1)[0]
            mean, sd = PREMIUM_PARAMS[ptype]
            premium = max(400, rng.gauss(mean, sd))
            premium *= CREDIT_EFFECT[holder_credit[holder_id]]["premium_mult"]
            # Young drivers (<25 at effective date) pay an Auto surcharge.
            effective = random_date(rng, date(2023, 1, 1), date(2025, 12, 31))
            age_at_effective = (effective - holder_dob[holder_id]).days // 365
            if ptype == "Auto" and age_at_effective < 25:
                premium *= 1.25
            premium = round(premium, 2)
            # Status: lapse / cancellation rise for Fair & Poor credit.
            r = rng.random()
            lapse_p = {"Excellent": 0.10, "Good": 0.16,
                       "Fair": 0.26, "Poor": 0.34}[holder_credit[holder_id]]
            if r < 0.10:
                status = "Cancelled"
            elif r < 0.10 + lapse_p:
                status = "Lapsed"
            else:
                status = "Active"
            rows.append({
                "policy_id": policy_id,
                "policyholder_id": holder_id,
                "agent_id": rng.choice(agent_ids),
                "policy_type": ptype,
                "coverage_limit": rng.choice(COVERAGE_LIMITS[ptype]),
                "deductible": rng.choice(DEDUCTIBLES[ptype]),
                "annual_premium": premium,
                "monthly_premium": round(premium / 12, 2),
                "effective_date": effective,
                "expiration_date": effective + timedelta(days=365),
                "status": status,
                "created_at": "2025-12-31 00:00:00",
                "updated_at": "2025-12-31 00:00:00",
            })
            policy_id += 1
    return pd.DataFrame(rows)


def gen_risk_profiles(rng: random.Random, policies: pd.DataFrame,
                      holders: pd.DataFrame) -> pd.DataFrame:
    holder_credit = dict(zip(holders["policyholder_id"],
                             holders["credit_score_band"]))
    holder_state = dict(zip(holders["policyholder_id"], holders["state"]))
    territory_risk = {"NY": 1.15, "MA": 1.08, "CT": 1.05,
                      "RI": 1.02, "NH": 0.95, "VT": 0.90}
    rows = []
    for _, pol in policies.iterrows():
        credit = holder_credit[pol["policyholder_id"]]
        centre = CREDIT_EFFECT[credit]["score"]
        score = int(max(300, min(900, rng.gauss(centre, 55))))
        prior = rng.choices([0, 1, 2, 3, 4], weights=[0.62, 0.22, 0.10, 0.04, 0.02])[0]
        # Risk score falls with prior claims; territory nudges it.
        score = int(max(300, min(900, score - prior * 28
                                 + (territory_risk[holder_state[pol["policyholder_id"]]] - 1.0) * -60)))
        tier = "Low" if score >= 720 else ("Medium" if score >= 620 else "High")
        rows.append({
            "profile_id": int(pol["policy_id"]),
            "policy_id": int(pol["policy_id"]),
            "risk_score": score,
            "risk_tier": tier,
            "prior_claims_3yr": prior,
            "territory_risk_factor": territory_risk[holder_state[pol["policyholder_id"]]],
            "years_insured": rng.randint(0, 15),
            "has_prior_cancellation": rng.random() < (0.18 if credit == "Poor" else 0.05),
        })
    return pd.DataFrame(rows)


def gen_claims(rng: random.Random, policies: pd.DataFrame,
               risk: pd.DataFrame, agents: pd.DataFrame) -> pd.DataFrame:
    pol_type = dict(zip(policies["policy_id"], policies["policy_type"]))
    pol_premium = dict(zip(policies["policy_id"], policies["annual_premium"]))
    pol_effective = dict(zip(policies["policy_id"], policies["effective_date"]))
    pol_expiry = dict(zip(policies["policy_id"], policies["expiration_date"]))
    risk_tier = dict(zip(risk["policy_id"], risk["risk_tier"]))
    agent_ids = agents["agent_id"].tolist()

    # Incident-first sampling: pick the incident date (seasonal, uniform
    # across 2023–2025), then pick a policy that was actually in force on
    # that date. Sampling the policy first and clamping the date into its
    # term biased incidents toward late 2025 and toward December.
    # Monthly buckets keep the "active on this date" lookup cheap.
    active_by_month: dict[tuple[int, int], list[int]] = {}
    base_weight: dict[int, float] = {}
    for _, pol in policies.iterrows():
        pid = int(pol["policy_id"])
        # Softer than the first draft (2.2/1.3/0.7): the steep weights piled
        # 145 policies up against the per-policy cap, a visible artefact.
        tier_w = 1.7 if risk_tier[pid] == "High" else (
            1.2 if risk_tier[pid] == "Medium" else 0.85)
        base_weight[pid] = tier_w * TYPE_FREQUENCY[pol["policy_type"]]
        d = pol_effective[pid].replace(day=1)
        last = pol_expiry[pid].replace(day=1)
        while d <= last:
            active_by_month.setdefault((d.year, d.month), []).append(pid)
            d = (d + timedelta(days=32)).replace(day=1)

    rows = []
    claims_per_policy: dict[int, int] = {}
    for claim_id in range(1, N_CLAIMS + 1):
        # Sample an incident date, then a live policy for that date.
        for _attempt in range(50):
            incident = seasonal_incident_date(rng, START_DATE, END_DATE)
            candidates = [pid for pid in active_by_month.get((incident.year, incident.month), [])
                          if pol_effective[pid] <= incident <= pol_expiry[pid]
                          and claims_per_policy.get(pid, 0) < MAX_CLAIMS_PER_POLICY]
            if candidates:
                break
        else:
            candidates = policies["policy_id"].tolist()
            incident = seasonal_incident_date(rng, START_DATE, END_DATE)
        pid = rng.choices(candidates,
                          weights=[base_weight[c] for c in candidates], k=1)[0]
        claims_per_policy[pid] = claims_per_policy.get(pid, 0) + 1
        ptype = pol_type[pid]
        ctype = rng.choices(CLAIM_TYPES[ptype],
                            weights=CLAIM_TYPE_WEIGHTS[ptype], k=1)[0]
        filed = incident + timedelta(days=rng.randint(0, 7))

        requested = lognormal_amount(rng, CLAIM_MEDIAN[ctype])
        requested = round(requested * TYPE_SEVERITY[ptype], 2)
        # A few large losses in the tail (fire / property) — capped so the
        # loss ratio stays in range; the cap is a generator choice, not data.
        requested = min(requested, 45_000.00)

        # Cycle time grows with severity: small ~12d, mid ~21d, large ~38d.
        if requested < 1_000:
            cycle = int(max(2, rng.gauss(12, 6)))
        elif requested < 5_000:
            cycle = int(max(3, rng.gauss(21, 9)))
        else:
            cycle = int(max(5, rng.gauss(38, 14)))
        closed_candidate = filed + timedelta(days=cycle)

        # Status: ~80% approved, ~12% denied, ~8% pending.
        # A claim whose settlement would run past the Dec 31, 2025 snapshot
        # is still open at snapshot time, so it is Pending — not artificially
        # closed on Dec 31.
        roll = rng.random()
        if closed_candidate > SNAPSHOT_DATE:
            status = "Pending"
        elif roll < 0.05:
            status = "Pending"
        elif roll < 0.17:
            status = "Denied"
        else:
            status = "Approved"

        if status == "Approved":
            paid = round(requested * rng.uniform(0.65, 0.95), 2)
            closed = closed_candidate
        elif status == "Denied":
            paid = 0.00
            # Denied claims close faster than paid ones.
            closed = filed + timedelta(days=int(max(2, rng.gauss(10, 5))))
            if closed > SNAPSHOT_DATE:
                closed = SNAPSHOT_DATE
        else:  # Pending
            paid = 0.00
            closed = None

        # Fraud: base ~1.0%, boosted for repeat claimants and for
        # claim-to-premium ratios above 3x. Target overall ~2–3%.
        n_prev = claims_per_policy[pid]
        fraud_prob = 0.010
        if n_prev >= 3:
            fraud_prob += 0.04
        if requested > 3 * pol_premium[pid]:
            fraud_prob += 0.03
        fraud_flag = rng.random() < fraud_prob
        fraud_score = round(
            min(99, rng.gauss(82, 10)) if fraud_flag else
            max(1, rng.gauss(18, 12)), 1)

        rows.append({
            "claim_id": claim_id,
            "policy_id": int(pid),
            "claim_type": ctype,
            "date_of_incident": incident,
            "date_filed": filed,
            "date_closed": closed,
            "claim_amount_requested": requested,
            "claim_amount_paid": paid,
            "status": status,
            "fraud_flag": fraud_flag,
            "fraud_score": fraud_score,
            "handling_agent_id": rng.choice(agent_ids),
        })
    return pd.DataFrame(rows)


def validate(holders, agents, policies, risk, claims) -> None:
    total_premium = policies["annual_premium"].sum()
    total_paid = claims["claim_amount_paid"].sum()
    loss_ratio = total_paid / total_premium
    denial = (claims["status"] == "Denied").mean()
    fraud = claims["fraud_flag"].mean()
    print(f"policyholders : {len(holders):,}")
    print(f"agents        : {len(agents):,}")
    print(f"policies      : {len(policies):,}  {policies['policy_type'].value_counts().to_dict()}")
    print(f"risk profiles : {len(risk):,}")
    print(f"claims        : {len(claims):,}  {claims['status'].value_counts().to_dict()}")
    print(f"claim window  : {claims['date_of_incident'].min()} to {claims['date_of_incident'].max()}")
    print(f"total premium : ${total_premium:,.0f}")
    print(f"total paid    : ${total_paid:,.0f}")
    print(f"LOSS RATIO    : {loss_ratio:.1%}  (target 60–75%)")
    print(f"denial rate   : {denial:.1%}  (target 10–15%)")
    print(f"fraud rate    : {fraud:.1%}  (target ~2–3%)")
    assert 0.60 <= loss_ratio <= 0.75, f"loss ratio {loss_ratio:.1%} out of range — retune CLAIM_MEDIAN"
    assert 0.10 <= denial <= 0.15, f"denial rate {denial:.1%} out of range"
    assert 0.015 <= fraud <= 0.04, f"fraud rate {fraud:.1%} out of range"
    print("Validation passed.")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    fake = Faker()
    Faker.seed(args.seed)

    holders = gen_policyholders(fake, rng)
    agents = gen_agents(fake, rng)
    policies = gen_policies(rng, holders, agents)
    risk = gen_risk_profiles(rng, policies, holders)
    claims = gen_claims(rng, policies, risk, agents)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, df in [("policyholders", holders), ("agents", agents),
                     ("policies", policies),
                     ("underwriting_risk_profiles", risk),
                     ("claims", claims)]:
        df.to_csv(OUT_DIR / f"{name}.csv", index=False)

    validate(holders, agents, policies, risk, claims)
    print(f"Wrote CSVs to {OUT_DIR}")


if __name__ == "__main__":
    main()
