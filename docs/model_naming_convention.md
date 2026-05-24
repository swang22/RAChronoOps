# Model Naming Convention

**Last updated:** 2026-05-21

---

## 1. Purpose

Two naming systems are in use in this project.  **Internal names** (M1, M2,
M3, HOPE-ED, HOPE-UC, …) are short identifiers used in code, file names,
and CSV column values.  **Paper names** are the full descriptive labels and
abbreviated short labels used in figures, tables, and prose when writing for
a general audience.

This document defines both systems, their rationale, and the canonical
mapping between them.

---

## 2. Internal names — rationale

Internal names are compact, collision-free identifiers chosen for code
readability and for stable file-naming across experiment iterations:

- `MC-NoStorage` — no storage, no dispatch optimization
- `M1`, `M1b`, `M1c`, `M1c_VREOnly`, `M1d_earliest`, `M1d_largest` — rule-based heuristics
- `M2` — event-window LP hybrid
- `M3` — full-year LP benchmark
- `HOPE-ED`, `HOPE-UC` — full-year HOPE model runs (ED = economic dispatch; UC = unit commitment)

`HOPE-ED` and `HOPE-UC` refer to the external HOPE production-cost model
(PCM) operated in two different modes.  They use the same computational
framework as M3 but add a more detailed plant-level representation and, for
HOPE-UC, binary commitment variables.

---

## 3. Paper names — rationale and definitions

Paper names describe what each method *does* rather than an opaque alphanumeric
label.  They serve two purposes:

1. Allow a reader without prior knowledge of the code to understand the
   method's key features from the name alone.
2. Align with accepted terminology in the resource adequacy and production-cost
   modelling literature.

### PCM-ED and PCM-UCED

The HOPE external model is a **Production-Cost Model (PCM)**.  Running it in
economic dispatch mode is **PCM-ED**; running with unit commitment is
**PCM-UCED** (Unit-Commitment Economic Dispatch).  These are the paper-facing
names for HOPE-ED and HOPE-UC respectively.

| Full paper name | Short label | Internal name |
|----------------|------------|---------------|
| PCM Economic Dispatch | PCM-ED | HOPE-ED |
| PCM Unit-Commitment Economic Dispatch | PCM-UCED | HOPE-UC |
| PCM Economic Dispatch (No Storage) | PCM-ED-NS | HOPE-ED-NoStorage |
| PCM Unit-Commitment Economic Dispatch (No Storage) | PCM-UCED-NS | HOPE-UC-NoStorage |

---

## 4. Canonical mapping table

| Internal name | Full paper name | Short label | Category | Placement |
|--------------|----------------|------------|----------|-----------|
| MC-NoStorage | Traditional Monte Carlo | Traditional MC | Heuristic (no storage) | Main |
| M1 | Naive Storage Monte Carlo | Naive Storage MC | Heuristic | Main |
| M1b | Reserve-Floor Storage Monte Carlo | Reserve-Floor MC | Heuristic | Main |
| M1c | Emergency-Only Storage Monte Carlo | Emergency-Only MC | Heuristic (PRAS/Evans-style) | Main |
| M1c\_VREOnly | VRE-Surplus-Only Charging Monte Carlo | VRE-Surplus MC | Heuristic | Appendix |
| M1d\_earliest | Risk-Hour-Earliest Monte Carlo | Risk-Hour-Earliest MC | Heuristic | Appendix |
| M1d\_largest | Risk-Hour-Largest Monte Carlo | Risk-Hour-Largest MC | Heuristic | Appendix |
| M2 | Event-Window LP Monte Carlo | Event-Window LP-MC | LP (windowed) | Main |
| M3 | Full-Year ED Monte Carlo | Full-Year ED-MC | LP (full year) | Main |
| HOPE-ED | PCM Economic Dispatch | PCM-ED | PCM (full year) | Main |
| HOPE-UC | PCM Unit-Commitment Economic Dispatch | PCM-UCED | PCM (full year) | Main |
| HOPE-ED-NoStorage | PCM Economic Dispatch (No Storage) | PCM-ED-NS | PCM (full year) | Appendix |
| HOPE-UC-NoStorage | PCM Unit-Commitment Economic Dispatch (No Storage) | PCM-UCED-NS | PCM (full year) | Appendix |

The machine-readable version of this table is `config/model_display_names.csv`.

---

## 5. Usage rules

### In paper prose

- On **first use** in a section: write the full paper name followed by the
  short label in parentheses, e.g.,  
  *"PCM Economic Dispatch (PCM-ED)"* or
  *"Emergency-Only Storage Monte Carlo (Emergency-Only MC, M1c internally)"*.
- On **subsequent use** in the same section: use only the short label
  (PCM-ED, Emergency-Only MC, etc.).
- Internal names (M1c, HOPE-UC, …) may appear in parentheses on first use
  to cross-reference the code, but should not be the primary label in prose.

### In paper tables

- Use the **short label** (PCM-ED, Emergency-Only MC, …) in table cells.
- The table caption or a footnote should state: "Internal code names appear in
  parentheses; the canonical mapping is in Table 1 (Model hierarchy)."

### In internal documentation (this repo)

- Internal names are preferred for clarity and code traceability.
- Paper names may be added in parentheses where context requires it.

---

## 6. Recommended main-text model ladder

The recommended progression for the main paper narrative, from simplest to
most complex:

1. **Traditional MC** (MC-NoStorage) — no-storage baseline
2. **Naive Storage MC** (M1) — cautionary failure case
3. **Reserve-Floor MC** (M1b) — improved heuristic
4. **Emergency-Only MC** (M1c) — PRAS/Evans-style conservative adequacy dispatch baseline
5. **Event-Window LP-MC** (M2) — proposed scalable optimization-assisted method
6. **Full-Year ED-MC** (M3) — LP reliability benchmark
7. **PCM-ED** (HOPE-ED) — PCM validation
8. **PCM-UCED** (HOPE-UC) — high-fidelity UC benchmark

Appendix models: Risk-Hour MC (M1d\_earliest / M1d\_largest),
VRE-Surplus MC (M1c\_VREOnly), PCM-ED-NS / PCM-UCED-NS.

---

## 7. Interpretation notes

**Emergency-Only MC (M1c)** is a PRAS/Evans-style conservative adequacy dispatch
rule: charge from system surplus; discharge only during pre-storage shortfall.
Analogous rules appear in PRAS (Stephen 2021) and Evans et al. (2019).
Its role in this project is **not** novelty as a standalone dispatch rule, but as a
validated low-cost baseline within the broader method ladder.  Avoid language
implying M1c is a newly invented dispatch strategy.

**Event-Window LP-MC (M2)** is the main scalable optimization-assisted method
proposed by this project.  It bridges conservative heuristic dispatch and full-year
ED by solving small LPs only around screened scarcity windows.  It is useful when
the simple emergency-only rule may not be sufficient — e.g., in systems with more
complex storage dynamics or when tighter accuracy on LOLH is required.
