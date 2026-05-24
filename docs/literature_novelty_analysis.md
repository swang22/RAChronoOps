# Literature Novelty Analysis

**Date:** 2026-05-22
**Purpose:** Document the novelty position of the RAChronoOps paper against the closest
literature on sequential MC resource adequacy with storage.

---

## 1. Papers Surveyed

22 papers across four search areas: (i) sequential MC resource adequacy with battery
storage, (ii) storage dispatch modeling in probabilistic RA, (iii) production-cost model /
unit commitment for RA, (iv) storage ELCC and capacity accreditation.

---

## 2. Novelty Matrix

| # | Paper | Storage modeled | Storage dispatch | Sequential MC | PCM/UC benchmark | RAChronoOps differentiator |
|---|---|---|---|---|---|---|
| P1 | Billinton & Li (1994) | No | — | Yes | No | Foundational text; no storage; no method ladder |
| P2 | Billinton & Allan (1996) | No | — | Yes | No | Pre-storage textbook |
| P3 | Evans, Tindemans & Angeli (2019) | Yes | Optimal no-forecast policy | No | No | Event-optimal policy theory; no full-year MC; no PCM |
| P4 | Tindemans & Strbac (2020) | Yes | Greedy EENS-min | Yes | No | MLMC acceleration only; no dispatch comparison; no PCM |
| P5 | Sharifnia & Tindemans (2022) | Yes | ML-surrogate | Yes | No | Surrogate acceleration; no method ladder |
| P6 | Zhang & Tindemans (2025) | Unclear | Surrogate | Yes | No | Training-aware speed metric; no dispatch ladder |
| P7 | Gunda et al. (2025) | Yes | Greedy (PRAS) | Yes | No | Correlated extreme events; greedy only; no PCM |
| P8 | **Gonzato, Bruninx & Delarue (2023)** | Yes | Multiple ED strategies | Yes | ED model | Shows EENS stable / LOLE varies — no heuristic-to-LP ladder; no PCM-UCED; no energy-sufficiency bound |
| P9 | Wang et al. (2022) | Yes | LP + convexified UC | No | Convexified UC | Capacity market design; no sequential MC ladder |
| P10 | Qi et al. (2025) | Yes | Pre/re-dispatch | Yes | No | Market strategy focus; no dispatch fidelity ladder |
| P11 | Zhang et al. (2026) | Yes | Marginal formulation | No | No | Accreditation reformulation; no sequential MC |
| P12 | Shi & Luo (2017) | Yes | 4 control strategies | Yes | No | Control strategy comparison; no LP/ED ladder; no PCM |
| P13 | Sun et al. (2022) | Yes | Hybrid config study | Yes | Yes (PCM) | Hybrid PV-storage sizing; no heuristic-to-ED ladder; no energy-sufficiency bound |
| P14 | **Mantegna et al. (2024)** | Yes | Rolling-horizon (recommended) | Yes | Yes | Survey/synthesis; no original experiments; no bound |
| P15 | Tillmanns et al. (2026) | Yes | Reviewed | Yes | Yes | Review paper; no original experiments |
| P16 | Sioshansi, Madaeni & Denholm (2014) | Yes | Dynamic programming | No | No | ELCC/EFC via DP; no sequential MC dispatch ladder |
| P17 | Muaddi & Singh (2022) | Yes | Implicit heuristic | No | No | Metric sensitivity only; no dispatch comparison |
| P18 | Pham, Cole & Gagnon (2024) | Yes | PRAS greedy | Yes | No | National planning scale; no dispatch quality analysis |
| P19 | Gonzalez-Aparicio et al. (2021) | Yes (PHS) | Multi-area sequential | Yes | No | Multi-area + transmission; no dispatch fidelity ladder |
| P20 | **Stephen / NREL PRAS (2021)** | Yes | Greedy (acknowledged simplification) | Yes | No | Tool documentation; greedy acknowledged as simplification — RAChronoOps quantifies the error |
| P21 | Rabecq et al. (2026) | Yes | LP SOC-constrained | Yes | No | Procurement optimization; no dispatch comparison ladder; no PCM-UCED |
| P22 | Barrows et al. (2020) — RTS-GMLC | Yes | — | — | — | Test-system description; mandatory system citation |

---

## 3. Defensible Novelty Claims

Claims are ordered from strongest to most incremental.  The framing reflects that
Emergency-Only MC (M1c) is a PRAS/Evans-style conservative adequacy dispatch rule —
not a newly invented strategy — and that the novelty is the systematic ladder,
error/runtime quantification, sufficiency bound, and PCM-UCED validation.

### Primary (anchor claim)
Building on prior work showing that storage dispatch affects adequacy metrics
(Gonzato et al. 2023; PRAS/Stephen 2021), RAChronoOps provides, to our knowledge,
the first **systematic storage-dispatch fidelity ladder** for sequential MC RA:
from naive proactive heuristics, to PRAS/Evans-style emergency-only dispatch, to
event-window LP, full-year ED, PCM-ED, and PCM-UCED — all benchmarked under common
random numbers on the public RTS-GMLC test system — with explicit quantification of
which approximations preserve EUE, LOLH, CVaR-EUE, and runtime performance.

### Secondary
The **storage-energy sufficiency bound** is an original diagnostic that explains
why emergency-only and event-window LP methods recover full-year ED EUE in the tested
cases.  To our knowledge, no prior paper derives or names this bound in the sequential
MC RA context.

### Third
Explicit decomposition of **PCM-UCED effects in tested storage-enabled cases**:
unit commitment changes LOLH and event timing but not EUE.  Gonzato et al. (P8)
make a related observation about EENS stability under dispatch variation, but without
a UC-level benchmark.

### Fourth (incremental but real)
The **no-storage exact equivalence** (traditional MC = LP = PCM-UCED) is implicitly
known but not previously demonstrated cleanly as a validated baseline on the RTS-GMLC
test system.

---

## 4. What Would Be Overclaiming

| Claim | Why it overclaims |
|---|---|
| "First to model storage in sequential MC RA" | False. PRAS (P20), Tindemans/Strbac (P4), Gonzato et al. (P8), and others do this. |
| "First to show peak-shaving heuristics overestimate risk" | Gonzato et al. (P8) and Mantegna et al. (P14) note this qualitatively. Correct framing: "first to systematically quantify and explain this bias against a PCM-UCED benchmark on a standard test system." |
| "First to use LP dispatch for storage in RA" | Wang et al. (P9) and Rabecq et al. (P21) use LP dispatch in RA contexts. The novelty is the comparison ladder and benchmark validation, not LP dispatch per se. |
| "Emergency-Only MC is a new dispatch strategy" | False. Analogous rules appear in PRAS (P20) and Evans et al. (P3). M1c's role is as a validated low-cost baseline within the ladder, not a novel standalone contribution. |
| "PCM-UCED does not affect EUE" (universal) | Result must be scoped: "in the tested single-zone RTS-GMLC cases." Add: "Commitment constraints may have a larger effect in systems with tighter flexibility." |
| "First sequential MC study with storage on RTS-GMLC" | Barrows et al. introduced RTS-GMLC with storage; PRAS applications use it. Novelty is the method ladder applied to it. |

---

## 5. References for the Introduction

These papers establish the problem motivation and the gap RAChronoOps fills.

| Paper | BibTeX key candidate | Role in Introduction |
|---|---|---|
| Mantegna et al. (2024) | `Mantegna2024maintaining` | Best motivation: "current practice is at crawl level; storage dispatch detail matters" — directly frames the gap |
| Tillmanns et al. (2026) | `Tillmanns2026review` | Authoritative recent review establishing that the field lacks a method-comparison ladder for storage dispatch in sequential MC |
| Stephen / PRAS (2021) | `Stephen2021pras` | PRAS explicitly acknowledges greedy dispatch as a simplification — motivates need to quantify the error |
| **Gonzato et al. (2023)** | `Gonzato2023effect` | **Closest prior work** — must be cited and differentiated: observes EENS stability but provides no method ladder, no UC benchmark, no sufficiency bound |
| Billinton & Li (1994) | `Billinton1994reliability` | Foundational sequential MC reference |
| Barrows et al. (2020) | `Barrows2020ieee` | RTS-GMLC system description — mandatory test-system citation |
| Wang et al. (2022) | `Wang2022crediting` | UC assumptions affect capacity credits — motivates PCM-UCED comparison |
| Sun et al. (2022) | `Sun2022insights` | PCM vs. probabilistic RA comparison — prior art on the PCM benchmark approach |

---

## 6. References for Methodology / Related Work

These papers require direct technical differentiation.

| Paper | BibTeX key candidate | Technical comparison point |
|---|---|---|
| Evans et al. (2019) | `Evans2019minimising` | Optimal no-forecast event policy — theoretical precursor to M1c's emergency-only design |
| Tindemans & Strbac (2020) | `Tindemans2020accelerating` | Same sequential MC + storage; RAChronoOps focuses on dispatch fidelity rather than sampling acceleration |
| Sharifnia & Tindemans (2022) | `Sharifnia2022multilevel` | ML-surrogate acceleration; complementary to RAChronoOps dispatch-fidelity focus |
| **Gonzato et al. (2023)** | `Gonzato2023effect` | Most direct overlap — differentiate: "we add PCM-UCED benchmark and energy-sufficiency bound that Gonzato et al. do not provide" |
| Rabecq et al. (2026) | `Rabecq2026stochastic` | Both use LP for storage in RA; RAChronoOps evaluates assessment accuracy, not procurement optimization |
| Sioshansi et al. (2014) | `Sioshansi2014dynamic` | DP-based capacity value — different computational paradigm; contrast with event-window LP approach |
| Pham et al. (2024) | `Pham2024average` | Large-scale PRAS greedy — RAChronoOps quantifies how much that greedy baseline errs |
| Gunda et al. (2025) | `Gunda2025correlated` | PRAS greedy applied to correlated extreme events — same motivation |

---

## 7. Suggested Introduction Gap Paragraph

> Sequential Monte Carlo resource adequacy assessment is the standard tool for
> chronological reliability evaluation [P1, P2], and recent reviews confirm it is
> increasingly needed as storage penetration grows [P14, P15].  Production-cost
> model tools can represent storage dispatch with full temporal fidelity but at
> high computational cost [P13]; practical RA tools such as PRAS [P20] use
> conservative adequacy-oriented dispatch (charge from surplus; discharge only to
> serve load) acknowledged as a simplification.  Prior work has shown that storage
> dispatch strategies affect reliability metrics: Gonzato et al. [P8] show that
> different dispatch strategies can yield the same EENS but different LOLE; Evans
> et al. [P3] derive optimal no-forecast dispatch policies for shortfall events.
> Building on these findings, what remains missing is a systematic
> storage-dispatch fidelity ladder — from naive proactive heuristics to
> PRAS/Evans-style emergency-only dispatch to event-window LP to full-year ED —
> that (i) benchmarks all levels against a PCM-UCED solution on a standard test
> system under common random numbers, and (ii) provides a diagnostic explanation
> for when and why simpler dispatch approximations recover full-year ED accuracy.
> This paper provides both.

---

## 8. Key Engagement Rule

**Gonzato et al. (2023) is the paper to engage most directly.**

They observe the same phenomenon — EENS is stable under dispatch variation while
LOLE differs — but do not:
- structure a heuristic-to-LP-to-full-year-ED method ladder,
- benchmark against a PCM-UCED solution,
- derive the storage-energy sufficiency bound that explains the convergence, or
- use a standard public test system (RTS-GMLC).

The Introduction and Related Work should include one sentence such as:
> "Gonzato et al. [P8] observe that EENS is stable across storage dispatch strategies
> while LOLE varies; we explain this via a storage-energy sufficiency bound and
> validate against a PCM-UCED benchmark on the RTS-GMLC system."

---

## 9. BibTeX Candidates

```bibtex
@book{Billinton1994reliability,
  author    = {R. Billinton and W. Li},
  title     = {Reliability Assessment of Electric Power Systems Using Monte Carlo Methods},
  publisher = {Plenum Press},
  year      = {1994}
}

@book{Billinton1996evaluation,
  author    = {R. Billinton and R. N. Allan},
  title     = {Reliability Evaluation of Power Systems},
  edition   = {2nd},
  publisher = {Plenum Press},
  year      = {1996}
}

@article{Evans2019minimising,
  author  = {M. P. Evans and S. H. Tindemans and D. Angeli},
  title   = {Minimising Unserved Energy Using Heterogeneous Storage Units},
  journal = {IEEE Transactions on Power Systems},
  volume  = {34},
  number  = {5},
  pages   = {3647--3656},
  year    = {2019},
  doi     = {10.1109/TPWRS.2019.2910388}
}

@article{Tindemans2020accelerating,
  author  = {S. H. Tindemans and G. Strbac},
  title   = {Accelerating System Adequacy Assessment using the Multilevel {Monte Carlo} Approach},
  journal = {Electric Power Systems Research},
  volume  = {189},
  pages   = {106740},
  year    = {2020}
}

@inproceedings{Sharifnia2022multilevel,
  author    = {E. Sharifnia and S. H. Tindemans},
  title     = {Multilevel {Monte Carlo} with Surrogate Models for Resource Adequacy Assessment},
  booktitle = {Proc. 17th Int. Conf. Probabilistic Methods Applied to Power Systems (PMAPS)},
  year      = {2022}
}

@article{Gunda2025correlated,
  author  = {T. Gunda and A. G. Moore and N. D. Jackson and S. C. Dhulipala and S. Awara},
  title   = {A resource adequacy assessment of correlated wide-area outages in the power grid},
  journal = {Environmental Research: Energy},
  volume  = {2},
  number  = {2},
  year    = {2025},
  doi     = {10.1088/2753-3751/add465}
}

@article{Gonzato2023effect,
  author  = {S. Gonzato and K. Bruninx and E. Delarue},
  title   = {The effect of short term storage operation on resource adequacy},
  journal = {Sustainable Energy, Grids and Networks},
  volume  = {34},
  pages   = {100999},
  year    = {2023},
  doi     = {10.1016/j.segan.2023.100999}
}

@article{Wang2022crediting,
  author  = {S. Wang and N. Zheng and C. D. Bothwell and Q. Xu and S. Kasina and B. F. Hobbs},
  title   = {Crediting Variable Renewable Energy and Energy Storage in Capacity Markets:
             Effects of Unit Commitment and Storage Operation},
  journal = {IEEE Transactions on Power Systems},
  volume  = {37},
  number  = {1},
  year    = {2022},
  doi     = {10.1109/TPWRS.2021.3081061}
}

@article{Shi2017capacity,
  author  = {N. Shi and Y. Luo},
  title   = {Capacity value of energy storage considering control strategies},
  journal = {PLOS ONE},
  volume  = {12},
  number  = {5},
  pages   = {e0178466},
  year    = {2017}
}

@article{Sun2022insights,
  author  = {Y. Sun and B. Frew and S. Dalvi and S. C. Dhulipala},
  title   = {Insights into Methodologies and Operational Details of Resource Adequacy
             Assessment: A Case Study with Application to a Broader Flexibility Framework},
  journal = {Applied Energy},
  volume  = {328},
  year    = {2022},
  doi     = {10.1016/j.apenergy.2022.120155}
}

@article{Mantegna2024maintaining,
  author  = {G. Mantegna and Z. Huang and G. {Van Caelenberg} and B. Frew and
             M. Lynch and M. O'Malley},
  title   = {Maintaining reliability while navigating unprecedented uncertainty:
             a synthesis of and guide to advances in electric sector resource adequacy},
  journal = {arXiv:2412.00533},
  year    = {2024}
}

@article{Tillmanns2026review,
  author  = {M. Tillmanns and J. A. Sch\"{o}ttler and A. J. Praktiknjo},
  title   = {A review of probabilistic resource adequacy assessments in power systems:
             Methods, applications, and future challenges},
  journal = {Energy Policy},
  volume  = {209},
  pages   = {114924},
  year    = {2026},
  doi     = {10.1016/j.enpol.2025.114924}
}

@article{Sioshansi2014dynamic,
  author  = {R. Sioshansi and S. H. Madaeni and P. Denholm},
  title   = {A Dynamic Programming Approach to Estimate the Capacity Value of Energy Storage},
  journal = {IEEE Transactions on Power Systems},
  volume  = {29},
  number  = {1},
  pages   = {395--403},
  year    = {2014},
  doi     = {10.1109/TPWRS.2013.2260424}
}

@techreport{Stephen2021pras,
  author      = {G. Stephen},
  title       = {Probabilistic Resource Adequacy Suite ({PRAS}) v0.6 Model Documentation},
  institution = {National Renewable Energy Laboratory},
  number      = {NREL/TP-5C00-79698},
  year        = {2021}
}

@techreport{Pham2024average,
  author      = {A. T. Pham and W. Cole and P. Gagnon},
  title       = {Average and Marginal Capacity Credit Values of Renewable Energy and
                 Battery Storage in the {United States} Power System},
  institution = {National Renewable Energy Laboratory},
  number      = {NREL/TP-7A40-89587},
  year        = {2024}
}

@article{GonzalezAparicio2021assessment,
  author  = {I. {Gonzalez-Aparicio} and A. Zucker and F. Careri and F. Monforti and T. Huld},
  title   = {Assessment of the Capacity Credit of Renewables and Storage in
             Multi-Area Power Systems},
  journal = {IEEE Transactions on Power Systems},
  volume  = {36},
  number  = {5},
  pages   = {4692--4702},
  year    = {2021},
  doi     = {10.1109/TPWRS.2020.3022812}
}

@article{Barrows2020ieee,
  author  = {C. Barrows and A. Bloom and A. Ehlen and J. Ik\"{a}heimo and
             J. Jorgenson and D. Krishnamurthy and J. Lau and B. McBennett and
             M. {O'Connell} and E. Preston and A. Staid and G. Stephen and J. Watson},
  title   = {The {IEEE} Reliability Test System: A Proposed 2019 Update},
  journal = {IEEE Transactions on Power Systems},
  volume  = {35},
  number  = {1},
  pages   = {119--127},
  year    = {2020},
  doi     = {10.1109/TPWRS.2019.2925557}
}
```

---

*Generated: 2026-05-22. Update when new closely related papers are identified.*
