# Figure Captions

---

**Figure 1 — Method hierarchy.**
Methodological ladder from the no-storage capacity-balance baseline to the
PCM unit-commitment benchmark.
Methods are ordered by increasing computational cost per Monte Carlo scenario
(from $<0.1$~s/scenario for heuristic methods to ${\sim}570$~s/scenario for
PCM-UCED).
\textit{Naive Storage MCS} and \textit{SOC-Floor Storage MCS} (\ding{55})
substantially overestimate reliability risk because proactive peak-shaving
discharge depletes storage state of charge before shortage events.
\textit{Emergency-Only Storage MCS} and \textit{Event-Window Storage MCS}
(\ding{51}) match the Full-Year ED EUE benchmark with ${\sim}150{\times}$
and ${\sim}22{\times}$ speedups, respectively.

---

**Figure 2 — EUE by storage dispatch method.**
Expected unserved energy (MWh/yr) for five storage dispatch methods,
$N=20$ Monte Carlo scenarios, seed~42, RTS-GMLC test system.
Panel~(a): balanced VRE portfolio; panel~(b): wind-heavy VRE portfolio.
All methods use common random numbers (identical outage sequences).
Dashed lines mark the Full-Year ED reference EUE in each panel.
\textit{Naive Storage MCS} and \textit{SOC-Floor Storage MCS} substantially
overestimate EUE because proactive discharge depletes storage before shortage events.
\textit{Emergency-Only Storage MCS}, \textit{Event-Window Storage MCS}, and
Full-Year ED produce identical EUE in both portfolios (bars reach the reference lines;
log scale).

---

**Figure 3 — Accuracy--runtime trade-off.**
Absolute EUE error relative to Full-Year ED as a function of per-scenario
computational runtime, balanced VRE portfolio, $N=20$, seed~42.
Methods with zero EUE error are shown at a floor of 0.05~MWh (annotated).
\textit{Emergency-Only Storage MCS} achieves zero EUE error at
${\sim}0.06$~s/scenario ($150{\times}$ faster than Full-Year ED at
${\sim}9.6$~s/scenario); \textit{Event-Window Storage MCS} achieves zero EUE
error at ${\sim}0.4$~s/scenario ($22{\times}$ faster).
PCM-UCED validates the EUE benchmark at ${\sim}570$~s/scenario.
Naive Storage MCS and SOC-Floor Storage MCS (lighter markers) are retained for
reference but are not part of the recommended frontier.

---

**Figure 4 — Event-shape metrics for storage-aware methods.**
Four event-shape statistics for the balanced VRE portfolio ($N=20$):
(a)~events per year, (b)~mean event duration, (c)~maximum event duration,
and (d)~maximum hourly shortfall.
All four methods produce identical EUE and NEUE (55~ppm); differences in
event-shape metrics reflect how the same total energy deficit is distributed
across shortage hours.
Emergency-Only Storage MCS and Full-Year ED agree on all event-shape statistics.
Event-Window Storage MCS produces more, shorter events (2.9 vs 2.0 events/yr,
mean duration 2.0 vs 3.0~h) because windowed LP optimization allocates the same
deficit differently.
PCM-UCED further fragments events (4.1 events/yr, 1.8~h mean) due to commitment
constraints, with a higher maximum shortfall.

---

**Appendix Figure 1 — Monte Carlo sampling convergence.**
(a) Expected unserved energy estimates with $95\%$ confidence interval
half-widths (shaded band and error bars on the Full-Year ED line) for $N =
20, 50, 100, 200$ scenarios.
Emergency-Only and Event-Window Storage MCS produce identical EUE to
Full-Year ED at every~$N$ (lines are coincident).
(b) Full-Year ED $95\%$ CI half-width as a function of~$N$ (EUE in solid
triangles, LOLH in dashed; right axis), with a $1/\sqrt{N}$ reference curve
(dash-dot).
Method EUE errors are $0.0$~MWh at all~$N$ (annotated); the figure confirms
that the EUE convergence result is not a small-sample artifact.

---

**Appendix Figure 2 — Representative shortage-event operation.**
Hourly load shedding during and around a representative five-hour shortage
event (hours 4984--4988, Scenario~15, balanced VRE portfolio, $N=20$).
Blue bars (Full-Year ED / Emergency-Only Storage MCS) and purple bars
(PCM-UCED) are grouped by hour; the shaded region marks the main event
window.
Both methods produce identical total EUE in the displayed window
(4\,572~MWh); differences reflect how PCM-UCED redistributes the same
deficit across hours under unit-commitment constraints.
PCM-UCED introduces one additional shedding hour (h4983) not present in
Full-Year ED, while reducing intensity at the end of the event.
Storage SOC and discharge are not output by the PCM model and are
therefore not shown.

---

**Figure 5 — Representative storage operation during shortage event.**
Representative storage operation during a balanced-VRE shortage event
(Scenario~15, $N=20$).
(a)~Load shedding (MW); (b)~aggregate storage discharge (MW);
(c)~aggregate state of charge (MWh).
The panels compare Emergency-only storage MCS, Event-window storage MCS, and
Full-year ED over a local event window centered on the first shedding hour
(relative hour~0).
All three methods produce the same total event EUE (4{,}572~MWh), but differ
in discharge timing and SOC trajectories.
Event-window storage MCS redistributes shortfall across more hours, whereas
Emergency-only storage MCS closely tracks Full-year ED.

---

**Appendix Figure 3 — Representative storage operation during shortage event (full window).**
Three-panel time-series for Scenario~15 (balanced VRE portfolio, $N=20$),
displaying the 90-hour window around the first shedding hour.
(a)~Load shedding (MW); (b)~aggregate storage discharge (MW);
(c)~aggregate state of charge (MWh).
Emergency-only storage MCS and Full-year ED produce identical load shedding
per scenario (overlapping lines in panel~a); their storage discharge and SOC
trajectories differ because Full-year ED optimizes dispatch over the full year
while Emergency-only MCS charges from system surplus and discharges only during
shortage.
Event-window storage MCS produces different load-shedding timing in this event:
it adds one shedding hour not present under the other methods and reaches a
higher maximum shortfall (1{,}440 vs 1{,}348~MW), illustrating that
LP-based event-window optimization can redistribute the same total EUE
across hours differently from the emergency-only heuristic.
Total EUE in the window is identical across all three methods (8{,}060~MWh).

---

**Appendix Figure 4 — Robustness across storage variants (balanced VRE, $N=20$).**
Full-Year ED expected unserved energy for 11 storage robustness variants
grouped by stress dimension: Experiment~A (storage duration 2--12~h at fixed
power), Experiment~B (storage power $0.5{\times}$--$2{\times}$ at fixed 4~h
duration), and Experiment~C (load scaling 1.225--1.25 with two storage
configurations).
Emergency-Only and Event-Window Storage MCS match the Full-Year ED EUE exactly
($\Delta = 0.0$~MWh) across all 11 variants, including the most stressed case
(load scale~1.225, 2-h storage, sufficiency ratio~0.69).
