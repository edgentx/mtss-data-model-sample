# MTSS Data Model, Sample Medallion Schema

Sample data model authored by **Edgent LLC** (SDVOSB, Bastrop TX) illustrating our data-modeling approach for a
K-12 **MTSS (Multi-Tiered System of Supports)** and community-schools analytics platform: a student roster spine
that carries subgroup attribution for every measure, attendance / behavior / assessment / social-emotional
facts, three-domain intervention plans with aim lines and progress monitoring, a community-services referral
pipeline with closed-loop tracking, graduation and readiness outcomes, and a published aggregate layer with
N-size suppression applied in the pipeline.

- `erd.dot` / `erd.svg` - entity-relationship diagram of the silver layer (Graphviz)
- `lineage.dot` / `lineage.svg` - which silver entities each published gold mart is built from (Graphviz)
- `silver.sql` - illustrative ANSI SQL DDL for the 19 silver entities
- `gold.sql` - illustrative ANSI SQL DDL for the 28 published gold marts, with the suppression contract

This is a **sample** for evaluation purposes. It is not the production schema of any Edgent system, it contains
no data, and it is not a delivered client engagement. The model is exercised against a synthetic, deterministic
demonstration district; every value in that dataset is generated, and no record originates from a real school
district, student, or staff member.

## What the model covers

### Silver: 19 typed entities

Silver is one row per business key, deduplicated, with the source system's identifiers resolved and its types
enforced. It is the layer analysts join against, and it is not published.

| Domain | Tables |
| --- | --- |
| Roster and enrollment | `students`, `enrollment_yearly` |
| Attendance | `attendance_daily`, `attendance_monthly` |
| Behavior | `incidents` |
| Assessment | `benchmarks` (universal screener), `state_assessments`, `assessments` (district interim) |
| Social and emotional learning | `sel_responses` |
| MTSS | `interventions`, `intervention_progress` |
| Community school services | `referrals`, `referral_events`, `services` |
| Graduation and readiness | `grad_outcomes`, `grad_tracker`, `ccr` |
| Workforce and programs | `staff`, `program_participation` |

### Gold: 28 published marts

Gold is what a dashboard, a public transparency site, or an external partner reads. Every table is a full
rebuild from silver, so any number a reader sees can be re-derived from the layer underneath it in one query.

| Domain | Tables |
| --- | --- |
| Enrollment and demographics | `enrollment_trends`, `enrollment_subgroups`, `key_indicators` |
| Achievement | `assessment_proficiency`, `benchmark_summary`, `school_year_metrics` |
| Attendance | `attendance_trends`, `attendance_chronic`, `attendance_distribution`, `attendance_by_month` |
| Behavior and climate | `behavior_per100`, `sel_climate`, `sel_window_comparison` |
| MTSS | `mtss_tiers`, `intervention_status`, `intervention_effectiveness`, `intervention_status_window`, `intervention_effectiveness_window` |
| Community school services | `community_services`, `community_services_window`, `service_dosage`, `service_correlation` |
| Graduation and readiness | `graduation_outcomes`, `grad_tracker_summary`, `college_career_readiness` |
| Workforce and programs | `staff_demographics`, `program_participation` |
| District summary | `district_kpis` |

## Why a medallion

The layering is not decoration. Each boundary exists to hold a rule that the layer above it cannot be trusted
to enforce.

**Bronze holds the arrival, unmodified.** Records land as immutable events carrying the envelope the source
system sent: identifier, source, subject, timestamp, and payload. Nothing is corrected here. When a source
system starts emitting a new field, or emits a bad one for six weeks, bronze is the record of what actually
arrived, and every downstream table can be rebuilt from it. A pipeline that corrects on ingest has no such
record and cannot answer "what did the district's own system say on the day we asked".

**Silver holds identity and type.** This is where duplicate events collapse to one row per business key, where
strings become dates and booleans, and where identity is resolved from the envelope rather than trusted from
the payload. It is also where cross-entity attribution is settled once: a student's school and grade come from
the enrollment spine, not from whichever fact row happens to carry them, so a subgroup breakdown cannot
disagree with itself depending on which measure a reader picked. Rebuilding silver heals the entire history,
including records that arrived wrong, without a backfill of the source events.

**Gold holds what may be published.** Suppression, disclosure-group logic, and the choice of which grains are
publishable all live here, in the pipeline, not in the reporting tool. Gold is also where the published grain
is stated explicitly: a district total is a row, not something a consumer computes by summing the school rows,
because summing a partially suppressed fine grain silently undercounts and presents the undercount as complete.

The practical payoff is that a rebuild is a full recomputation, not a patch. A definition change (a different
chronic-absence threshold, a corrected subgroup mapping, a fixed source feed) is applied by rebuilding silver
and gold from bronze, and the whole history moves with it.

## N-size suppression and FERPA posture

Suppression happens in the **pipeline**, not in the dashboard. A reporting layer that hides small cells at
render time has still shipped them to the browser and still stored them where the next consumer will read
them unsuppressed. In this model a cell below the threshold is written as NULL and never leaves the warehouse.

1. **Threshold.** Any measure whose underlying count is below 10 is nulled.
2. **Complementary suppression.** When exactly one cell in a disclosure group is suppressed, the next-smallest
   cell is suppressed too. Otherwise the hidden value is recoverable by subtracting the published cells from a
   published total.
3. **An explicit column.** Every suppression-bearing mart carries `suppressed BOOLEAN`. A reader is told
   "withheld for privacy", never shown a gap that reads as zero.
4. **Rates follow their denominators.** A percentage over a small denominator hands back the numerator, so a
   rate is suppressed when the count it divides by is below threshold even if the rate's own cell is large.
5. **Partitions publish together or not at all.** Tier 1 / 2 / 3, or opened versus closed referrals, are parts
   of one whole: publishing two parts and withholding the third republishes the third by subtraction.
6. **Trailing windows are checked against each other.** The 30, 90, and 365 day marts and their to-date twins
   are suppressed as a family, because a reader holding two of them can subtract one from the other.

A distinction the model insists on: **NULL is not always suppression.** A rate over a denominator of zero (a
closed-loop rate where no referrals were opened) has no value to withhold. Labeling that "suppressed for
privacy" is a statement the data does not support, and it teaches readers to discount the privacy label
everywhere else. The two states are carried separately.

**FERPA posture.** Public surfaces read gold and only gold. No gold table contains a student identifier, a
staff identifier, a name, a date of birth, or a free-text field a person could be recognized in. Row-level
access to silver is a separate and narrower grant held by district staff; the public read credential resolves
to the published marts alone. Demographic attributes in silver are coarse reporting buckets chosen so that
aggregates over them can clear the threshold, and no name, address, date of birth, or contact field appears
anywhere in the model.

## Design notes

- **The roster is the spine.** Every subgroup breakdown attributes from `silver.students` (or
  `silver.enrollment_yearly` for a historical year), never from the fact row carrying the measure. A student
  who is coded one way on an assessment record and another way on an attendance record would otherwise produce
  two different denominators for the same population.
- **Enrollment is the denominator.** A student absent from the enrollment spine for a year did not have zero
  attendance that year, they were not enrolled. Rates read their denominator from the spine.
- **Aim lines are stored as parameters.** An intervention keeps `aim_start`, `aim_goal`, and `aim_target_date`
  rather than a rendered series, so progress can be scored against the line at any observation date; and
  `intervention_progress.on_aim` stores the judgement so it travels with the observation and is not silently
  re-scored by a later edit to the plan.
- **Closed-loop is narrower than terminal.** A community-services referral that ends "Unable to Contact" is
  terminal and is not a success. The two counts stay separate columns, because collapsing them is how a
  referral pipeline reports service delivery it did not achieve.
- **Trailing windows are separate tables from to-date totals.** The two answer different questions and have
  different suppression outcomes, and publishing them as one table with a filter would make the suppression
  decision depend on the reader's filter.
- **The headline agrees with the table under it.** `gold.district_kpis` is recomputed from silver and then
  asserted against the marts before the build is allowed to succeed. A summary figure that disagrees with the
  detail beneath it fails the pipeline rather than reaching a reader.
- **Correlation is named correlation.** `gold.service_correlation` compares served and comparison cohorts that
  were not randomized, and the table's name says so. It exists so a program conversation starts from measured
  differences rather than anecdote, not to support a causal claim.
