-- Gold layer: published aggregates. This is the only layer a dashboard,
-- a public transparency site, or an external partner ever reads.
--
-- Illustrative ANSI SQL DDL for the MTSS sample data model (Edgent LLC).
-- Every table here is fully derived from silver by a pipeline that rebuilds
-- it; nothing is hand-entered, and no gold row can carry a value that is not
-- reproducible from the silver rows underneath it.
--
-- THE SUPPRESSION CONTRACT
--
-- Suppression happens in the PIPELINE, not in the dashboard. A reporting layer
-- that hides small cells at render time still shipped them to the browser, and
-- still stored them where the next consumer will read them unsuppressed. Here,
-- a cell below the N-size threshold is written as NULL and never leaves the
-- warehouse.
--
--   1. Threshold. Any measure whose underlying count is below 10 is nulled.
--   2. Complementary suppression. When exactly one cell in a disclosure group
--      is suppressed, the next-smallest cell in that group is suppressed too.
--      Otherwise the hidden value is recoverable by subtracting the published
--      cells from a published total.
--   3. An explicit column. Every suppression-bearing table carries
--      `suppressed BOOLEAN`. A reader is told "withheld for privacy", never
--      shown a gap that reads as zero.
--   4. Rates follow their denominators. A percentage over a small denominator
--      hands back the numerator, so a rate is suppressed when the count it
--      divides by is below threshold, even if the rate's own cell is large.
--   5. Partitions publish together or not at all. Tier 1/2/3, or opened
--      vs closed referrals, are parts of one whole: publishing two parts and
--      withholding the third republishes the third by subtraction.
--
-- A separate and equally important rule: NULL is not always suppression.
-- A rate over a denominator of zero (a closed-loop rate where no referrals
-- were opened) has no value to withhold. Labeling that "suppressed for
-- privacy" is a statement the data does not support, and it teaches readers to
-- discount the privacy label everywhere else. Consuming surfaces distinguish
-- the two states; `suppressed` is false in the second case.
--
-- FERPA POSTURE
--
-- Public surfaces read gold and only gold. No table in this layer contains a
-- student identifier, a staff identifier, a name, a date of birth, or any
-- free-text field a person could be recognized in. The joins that touch
-- student-level rows happen inside the pipeline, under a service identity
-- whose authorization is scoped to the schemas it builds. Row-level access to
-- silver is a separate, narrower grant held by district staff, and the public
-- read credential resolves to the gold tables alone.
--
-- Conventions
--   * `level` names the grain of a row in tables that publish several grains
--     from one build: 'district', 'school', 'district_grade', 'school_grade',
--     'district_subgroup'. Rows at different levels must never be added
--     together, and publishing the coarse grain explicitly is what stops a
--     consumer from re-deriving it by summing the fine one over suppressed
--     cells.
--   * `window_days` marts (30 / 90 / 365) publish a TRAILING window. They are
--     separate tables from their to-date twins because the two answer
--     different questions and have different suppression outcomes.
--   * Percentage columns are 0..100, not 0..1.
--
-- This is a SAMPLE. It is not the production schema of any Edgent system and
-- it holds no data from any school district.

CREATE SCHEMA gold;

-- ---------------------------------------------------------------------------
-- Enrollment and demographics
-- ---------------------------------------------------------------------------

-- Enrollment counts by year, building, and grade. school_id = 'district' and
-- grade = 'all' carry the rolled-up totals as published rows.
CREATE TABLE gold.enrollment_trends (
  school_year  VARCHAR(9)  NOT NULL,
  school_id    VARCHAR(32) NOT NULL,  -- building key, or 'district'
  grade        VARCHAR(4)  NOT NULL,  -- grade, or 'all'
  n            INTEGER     NOT NULL,  -- students enrolled
  CONSTRAINT enrollment_trends_pk PRIMARY KEY (school_year, school_id, grade)
);

-- Enrollment composition by reporting subgroup.
CREATE TABLE gold.enrollment_subgroups (
  school_year    VARCHAR(9)  NOT NULL,
  school_id      VARCHAR(32) NOT NULL,
  subgroup_type  VARCHAR(32) NOT NULL,  -- race_ethnicity | ell | iep | frpl
  subgroup       VARCHAR(64) NOT NULL,  -- the value within that type
  n              INTEGER,               -- NULL when suppressed
  pct            DECIMAL(5,1),          -- share of the school year, NULL when suppressed
  suppressed     BOOLEAN     NOT NULL,
  CONSTRAINT enrollment_subgroups_pk PRIMARY KEY (school_year, school_id, subgroup_type, subgroup)
);

-- The four key indicator groups that place a student on the MTSS continuum,
-- published by school and grade and by district subgroup.
CREATE TABLE gold.key_indicators (
  level          VARCHAR(24) NOT NULL,  -- school_grade | district_subgroup
  school_id      VARCHAR(32) NOT NULL,
  grade          VARCHAR(4)  NOT NULL,
  subgroup_type  VARCHAR(32) NOT NULL,  -- 'all' at school_grade level
  subgroup       VARCHAR(64) NOT NULL,
  key_indicator  VARCHAR(32) NOT NULL,  -- on_track_college_career |
                                        -- on_track_graduation | at_risk | critical
  n              INTEGER,
  pct            DECIMAL(5,1),
  suppressed     BOOLEAN     NOT NULL,
  CONSTRAINT key_indicators_pk PRIMARY KEY (level, school_id, grade, subgroup_type, subgroup, key_indicator)
);

-- ---------------------------------------------------------------------------
-- Achievement
-- ---------------------------------------------------------------------------

-- State assessment proficiency by school and by district subgroup. `family`
-- separates the grade 3-8 program from end-of-course exams; a rate is never
-- computed across both.
CREATE TABLE gold.assessment_proficiency (
  level           VARCHAR(24) NOT NULL,  -- school | district_subgroup
  family          VARCHAR(32) NOT NULL,
  subject_area    VARCHAR(32) NOT NULL,
  school_id       VARCHAR(32) NOT NULL,
  subgroup_type   VARCHAR(32) NOT NULL,
  subgroup        VARCHAR(64) NOT NULL,
  n               INTEGER,
  pct_proficient  DECIMAL(5,1),
  avg_level       DECIMAL(4,2),          -- mean performance level, 1..5
  suppressed      BOOLEAN     NOT NULL,
  CONSTRAINT assessment_proficiency_pk PRIMARY KEY (level, family, subject_area, school_id, subgroup_type, subgroup)
);

-- Universal screener results and within-year growth. avg_growth is the mean of
-- per-student differences, not the difference of the means: the two disagree
-- whenever the tested population changes between windows, and only the first
-- is a growth statement.
CREATE TABLE gold.benchmark_summary (
  platform            VARCHAR(32) NOT NULL,
  subject_area        VARCHAR(32) NOT NULL,
  school_id           VARCHAR(32) NOT NULL,  -- building key, or 'district'
  n                   INTEGER     NOT NULL,
  avg_boy_percentile  DECIMAL(5,1),
  avg_moy_percentile  DECIMAL(5,1),
  avg_growth          DECIMAL(5,1),          -- mean per-student percentile change
  on_benchmark_n      INTEGER,               -- screener tier counts at mid-year
  strategic_n         INTEGER,
  intensive_n         INTEGER,
  CONSTRAINT benchmark_summary_pk PRIMARY KEY (platform, subject_area, school_id)
);

-- District interim assessment rollup: the layer that lets attendance and
-- achievement be read together at one grain.
CREATE TABLE gold.school_year_metrics (
  school_id           VARCHAR(32)  NOT NULL,
  school_year         VARCHAR(9)   NOT NULL,
  subject             VARCHAR(16)  NOT NULL,  -- ela | math | science
  n_students          INTEGER      NOT NULL,
  attendance_rate     DECIMAL(5,4) NOT NULL,  -- days present / days enrolled
  chronic_absent_pct  DECIMAL(5,4) NOT NULL,  -- share of students below 90 percent
  avg_scale_score     DECIMAL(8,1) NOT NULL,
  proficient_pct      DECIMAL(5,4) NOT NULL,
  CONSTRAINT school_year_metrics_pk PRIMARY KEY (school_id, school_year, subject)
);

-- ---------------------------------------------------------------------------
-- Attendance
-- ---------------------------------------------------------------------------

-- Daily attendance line. Suppression rides on marked_n: a day with fewer than
-- ten marks in a building publishes the row with its measures nulled, so a
-- consuming chart draws a break rather than inventing a zero.
CREATE TABLE gold.attendance_trends (
  attendance_date  DATE         NOT NULL,
  school_year      VARCHAR(9)   NOT NULL,
  school_id        VARCHAR(32)  NOT NULL,  -- building key, or 'district'
  marked_n         INTEGER,                -- attendance marks behind the day
  ada_pct          DECIMAL(5,1),           -- present or tardy, as a percentage
  absent_n         INTEGER,
  tardy_n          INTEGER,
  suppressed       BOOLEAN      NOT NULL,
  CONSTRAINT attendance_trends_pk PRIMARY KEY (attendance_date, school_id)
);

-- Chronic absenteeism by building, year to date. chronic_threshold_pct is
-- published as data rather than hard-coded into the reader, so the definition
-- in force is always visible next to the number it produced.
CREATE TABLE gold.attendance_chronic (
  school_id              VARCHAR(32)  NOT NULL,
  students_n             INTEGER,
  ada_pct                DECIMAL(5,1),
  chronic_n              INTEGER,                -- students at or above the threshold
  chronic_pct            DECIMAL(5,1),
  chronic_threshold_pct  DECIMAL(4,1) NOT NULL,  -- share of enrolled days missed
  suppressed             BOOLEAN      NOT NULL,
  CONSTRAINT attendance_chronic_pk PRIMARY KEY (school_id)
);

-- Days-missed histogram. This exists so the chronic-absence threshold can be
-- moved by a reader without a pipeline change: re-thresholding is a sum over
-- buckets, not a rebuild.
CREATE TABLE gold.attendance_distribution (
  school_id           VARCHAR(32) NOT NULL,  -- building key, or 'district'
  days_missed_bucket  VARCHAR(16) NOT NULL,  -- '00-04.9' | '05-09.9' | '10-19.9' | '20+'
  n                   INTEGER     NOT NULL,
  CONSTRAINT attendance_distribution_pk PRIMARY KEY (school_id, days_missed_bucket)
);

-- Monthly attendance rollup, built from the monthly silver grain.
CREATE TABLE gold.attendance_by_month (
  school_id        VARCHAR(32)  NOT NULL,
  school_year      VARCHAR(9)   NOT NULL,
  month_number     SMALLINT     NOT NULL,
  days_possible    INTEGER      NOT NULL,
  days_present     INTEGER      NOT NULL,
  attendance_rate  DECIMAL(5,4) NOT NULL,
  CONSTRAINT attendance_by_month_pk PRIMARY KEY (school_id, school_year, month_number)
);

-- ---------------------------------------------------------------------------
-- Behavior and climate
-- ---------------------------------------------------------------------------

-- Incidents and exclusionary discipline per 100 enrolled students, by month.
-- Per-100 rather than raw counts because buildings differ in size by an order
-- of magnitude and a raw count ranks by enrollment, not by climate.
CREATE TABLE gold.behavior_per100 (
  school_id          VARCHAR(32) NOT NULL,
  month              VARCHAR(7)  NOT NULL,  -- 'YYYY-MM'
  school_year        VARCHAR(9)  NOT NULL,
  enrolled_n         INTEGER,
  incidents_n        INTEGER,
  incidents_per100   DECIMAL(6,2),
  iss_per100         DECIMAL(6,2),          -- in-school suspensions
  oss_per100         DECIMAL(6,2),          -- out-of-school suspensions
  expulsions_per100  DECIMAL(6,2),
  suppressed         BOOLEAN     NOT NULL,
  CONSTRAINT behavior_per100_pk PRIMARY KEY (school_id, month)
);

-- SEL perception averages by administration and respondent type. This is
-- student mental-health perception data, so the N-size rule binds hardest
-- here: a small school crossed with a respondent type suppresses readily and
-- is meant to.
CREATE TABLE gold.sel_climate (
  school_id                   VARCHAR(32)  NOT NULL,  -- building key, or 'district'
  survey_window               VARCHAR(32)  NOT NULL,
  respondent                  VARCHAR(16)  NOT NULL,  -- student | teacher | family
  n                           INTEGER,
  self_awareness              DECIMAL(3,2),
  self_management             DECIMAL(3,2),
  social_awareness            DECIMAL(3,2),
  relationship_skills         DECIMAL(3,2),
  responsible_decision_making DECIMAL(3,2),
  level                       VARCHAR(16)  NOT NULL,  -- district | school
  suppressed                  BOOLEAN      NOT NULL,
  CONSTRAINT sel_climate_pk PRIMARY KEY (school_id, survey_window, respondent)
);

-- Administration-over-administration SEL change. The prior window is resolved
-- CHRONOLOGICALLY from recorded_at, not alphabetically from the window name.
-- is_baseline marks the first administration, which has nothing to compare to
-- and must not be rendered as a change of zero.
CREATE TABLE gold.sel_window_comparison (
  school_id          VARCHAR(32)  NOT NULL,
  respondent         VARCHAR(16)  NOT NULL,
  competency         VARCHAR(48)  NOT NULL,  -- one of the five SEL competencies
  school_year        VARCHAR(9)   NOT NULL,
  survey_window      VARCHAR(32)  NOT NULL,
  window_label       VARCHAR(64),
  first_response_at  TIMESTAMP,              -- chronological anchor for the window
  prior_window       VARCHAR(32),            -- NULL at baseline
  n                  INTEGER,
  mean_score         DECIMAL(3,2),
  prior_n            INTEGER,
  prior_mean_score   DECIMAL(3,2),
  delta              DECIMAL(4,2),           -- mean_score - prior_mean_score
  pct_change         DECIMAL(6,1),
  suppressed         BOOLEAN      NOT NULL,
  is_baseline        BOOLEAN      NOT NULL,
  CONSTRAINT sel_window_comparison_pk PRIMARY KEY (school_id, respondent, competency, survey_window)
);

-- ---------------------------------------------------------------------------
-- MTSS
-- ---------------------------------------------------------------------------

-- Tier distribution. The three tiers PARTITION the population, so all three
-- publish or none does: normalizing two of them republishes a share of a total
-- the data no longer gives.
CREATE TABLE gold.mtss_tiers (
  school_id   VARCHAR(32) NOT NULL,
  grade       VARCHAR(4)  NOT NULL,  -- grade, or 'all'
  mtss_tier   SMALLINT    NOT NULL,
  n           INTEGER,
  level       VARCHAR(24) NOT NULL,  -- district | school | district_grade | school_grade
  suppressed  BOOLEAN     NOT NULL,
  CONSTRAINT mtss_tiers_pk PRIMARY KEY (level, school_id, grade, mtss_tier)
);

-- Intervention plan counts by support domain and lifecycle status, to date.
CREATE TABLE gold.intervention_status (
  school_id   VARCHAR(32) NOT NULL,
  domain      VARCHAR(16) NOT NULL,  -- academic | behavioral | attendance
  status      VARCHAR(16) NOT NULL,  -- active | completed | discontinued
  n           INTEGER,
  level       VARCHAR(16) NOT NULL,  -- district | school
  suppressed  BOOLEAN     NOT NULL,
  CONSTRAINT intervention_status_pk PRIMARY KEY (level, school_id, domain, status)
);

-- Does the intervention work: outcome rates by domain and tier, to date.
-- met_goal_pct divides by completed_n, so it is suppressed whenever
-- completed_n is itself below threshold even when the cell total is large.
CREATE TABLE gold.intervention_effectiveness (
  domain          VARCHAR(16) NOT NULL,
  mtss_tier       SMALLINT    NOT NULL,
  n               INTEGER,
  active_n        INTEGER,
  completed_n     INTEGER,
  discontinued_n  INTEGER,
  met_goal_pct    DECIMAL(5,1),  -- completed plans that met their goal
  on_aim_pct      DECIMAL(5,1),  -- latest progress observations at or above aim
  suppressed      BOOLEAN     NOT NULL,
  CONSTRAINT intervention_effectiveness_pk PRIMARY KEY (domain, mtss_tier)
);

-- Trailing-window twin of intervention_status: plans active at ANY point in
-- the window. Suppression is evaluated across the window family and against
-- the to-date table, because a reader holding both the 30 and 90 day cells can
-- subtract one from the other.
CREATE TABLE gold.intervention_status_window (
  window_days  SMALLINT    NOT NULL,  -- 30 | 90 | 365
  level        VARCHAR(16) NOT NULL,
  school_id    VARCHAR(32) NOT NULL,
  domain       VARCHAR(16) NOT NULL,
  status       VARCHAR(16) NOT NULL,
  n            INTEGER,
  students_n   INTEGER,
  suppressed   BOOLEAN     NOT NULL,
  CONSTRAINT intervention_status_window_pk PRIMARY KEY (window_days, level, school_id, domain, status)
);

-- Trailing-window twin of intervention_effectiveness.
CREATE TABLE gold.intervention_effectiveness_window (
  window_days     SMALLINT    NOT NULL,  -- 30 | 90 | 365
  domain          VARCHAR(16) NOT NULL,
  mtss_tier       SMALLINT    NOT NULL,
  n               INTEGER,
  active_n        INTEGER,
  completed_n     INTEGER,
  discontinued_n  INTEGER,
  met_goal_pct    DECIMAL(5,1),
  on_aim_pct      DECIMAL(5,1),
  suppressed      BOOLEAN     NOT NULL,
  CONSTRAINT intervention_effectiveness_window_pk PRIMARY KEY (window_days, domain, mtss_tier)
);

-- ---------------------------------------------------------------------------
-- Community school services
-- ---------------------------------------------------------------------------

-- Referral and service delivery by building, partner, and service category,
-- to date. closed_loop_pct is the confirmed-service rate, not the terminal
-- rate: a referral that ended 'Unable to Contact' is closed and is not a
-- success, and the two counts stay separate columns for that reason.
CREATE TABLE gold.community_services (
  school_id          VARCHAR(32)  NOT NULL,  -- building key, or 'district'
  partner_name       VARCHAR(128) NOT NULL,
  service_category   VARCHAR(64)  NOT NULL,
  referrals_n        INTEGER,
  students_n         INTEGER,
  closed_loop_pct    DECIMAL(5,1),
  terminal_n         INTEGER,                -- referrals that reached any terminal state
  sessions_total     INTEGER,
  hours_total        DECIMAL(10,2),
  avg_days_to_close  DECIMAL(6,1),
  level              VARCHAR(16)  NOT NULL,  -- district | school
  suppressed         BOOLEAN      NOT NULL,
  CONSTRAINT community_services_pk PRIMARY KEY (level, school_id, partner_name, service_category)
);

-- Trailing-window twin of community_services. referrals_opened_n and
-- referrals_closed_n are two parts of one partition, so the mart withholds
-- both unless each part and their difference clear the threshold.
CREATE TABLE gold.community_services_window (
  window_days         SMALLINT     NOT NULL,  -- 30 | 90 | 365
  level               VARCHAR(16)  NOT NULL,
  school_id           VARCHAR(32)  NOT NULL,
  partner_name        VARCHAR(128) NOT NULL,
  service_category    VARCHAR(64)  NOT NULL,
  students_n          INTEGER,
  referrals_opened_n  INTEGER,
  referrals_closed_n  INTEGER,                -- closed-loop within the window
  sessions_total      INTEGER,
  hours_total         DECIMAL(10,2),
  suppressed          BOOLEAN      NOT NULL,
  CONSTRAINT community_services_window_pk
    PRIMARY KEY (window_days, level, school_id, partner_name, service_category)
);

-- Service dosage by category and grade band: how much service a served student
-- actually received, not how many were referred.
CREATE TABLE gold.service_dosage (
  service_category          VARCHAR(64) NOT NULL,
  grade_band                VARCHAR(16) NOT NULL,  -- elementary | middle | high
  students_served           INTEGER,
  total_sessions            INTEGER,
  total_hours               DECIMAL(10,2),
  avg_sessions_per_student  DECIMAL(6,2),
  avg_hours_per_student     DECIMAL(6,2),
  suppressed                BOOLEAN     NOT NULL,
  CONSTRAINT service_dosage_pk PRIMARY KEY (service_category, grade_band)
);

-- Served versus comparison outcomes by service category. This is a
-- CORRELATION table and is named one: the cohorts are not randomized and the
-- model does not claim they are. It exists so a program conversation starts
-- from measured differences rather than from anecdote.
CREATE TABLE gold.service_correlation (
  service_category          VARCHAR(64) NOT NULL,
  cohort                    VARCHAR(16) NOT NULL,  -- served | comparison
  n                         INTEGER,
  avg_attendance_pct        DECIMAL(5,1),
  avg_incidents             DECIMAL(6,2),
  avg_benchmark_percentile  DECIMAL(5,1),
  avg_sel_score             DECIMAL(3,2),
  suppressed                BOOLEAN     NOT NULL,
  CONSTRAINT service_correlation_pk PRIMARY KEY (service_category, cohort)
);

-- ---------------------------------------------------------------------------
-- Graduation and readiness
-- ---------------------------------------------------------------------------

-- Cohort graduation outcomes: the four, five, and six year rates plus the
-- dropout rate, by building and by district subgroup. All four read the same
-- cohort denominator.
CREATE TABLE gold.graduation_outcomes (
  level          VARCHAR(24) NOT NULL,  -- district | school | district_subgroup
  cohort_year    SMALLINT    NOT NULL,  -- entering-ninth-grade year
  school_year    VARCHAR(9)  NOT NULL,  -- the cohort's on-time graduation year
  school_id      VARCHAR(32) NOT NULL,
  subgroup_type  VARCHAR(32) NOT NULL,
  subgroup       VARCHAR(64) NOT NULL,
  n              INTEGER,
  grad_4yr_pct   DECIMAL(5,1),
  grad_5yr_pct   DECIMAL(5,1),
  grad_6yr_pct   DECIMAL(5,1),
  dropout_pct    DECIMAL(5,1),
  suppressed     BOOLEAN     NOT NULL,
  CONSTRAINT graduation_outcomes_pk PRIMARY KEY (level, cohort_year, school_id, subgroup_type, subgroup)
);

-- Forward-looking on-track summary for currently enrolled high school
-- students. This is the table that turns graduation from a lagging indicator
-- into one a school can still act on.
CREATE TABLE gold.grad_tracker_summary (
  school_id              VARCHAR(32)  NOT NULL,  -- building key, or 'district'
  grade                  VARCHAR(4)   NOT NULL,  -- grade, or 'all'
  n                      INTEGER      NOT NULL,
  on_track_pct           DECIMAL(5,1),
  avg_credits_earned     DECIMAL(5,1),
  avg_state_exams_passed DECIMAL(4,2),
  CONSTRAINT grad_tracker_summary_pk PRIMARY KEY (school_id, grade)
);

-- College and career readiness participation rates by building.
CREATE TABLE gold.college_career_readiness (
  school_id               VARCHAR(32) NOT NULL,
  n                       INTEGER,
  ap_ib_pct               DECIMAL(5,1),
  dual_enrollment_pct     DECIMAL(5,1),
  tech_certification_pct  DECIMAL(5,1),
  suppressed              BOOLEAN     NOT NULL,
  CONSTRAINT college_career_readiness_pk PRIMARY KEY (school_id)
);

-- ---------------------------------------------------------------------------
-- Workforce, programs, and the district summary
-- ---------------------------------------------------------------------------

-- Staff composition by building and role band.
CREATE TABLE gold.staff_demographics (
  school_id      VARCHAR(32) NOT NULL,  -- building key, or 'district'
  role_band      VARCHAR(32) NOT NULL,
  subgroup_type  VARCHAR(32) NOT NULL,  -- race_ethnicity | gender | grade_band
  subgroup       VARCHAR(64) NOT NULL,
  n              INTEGER,
  pct            DECIMAL(5,1),
  suppressed     BOOLEAN     NOT NULL,
  CONSTRAINT staff_demographics_pk PRIMARY KEY (school_id, role_band, subgroup_type, subgroup)
);

-- Program participation by building and by district subgroup: who is reached
-- by each initiative, which is the question an equity review actually asks.
CREATE TABLE gold.program_participation (
  level          VARCHAR(24)  NOT NULL,  -- school | district_subgroup
  program_id     VARCHAR(32)  NOT NULL,
  program_name   VARCHAR(128) NOT NULL,
  school_id      VARCHAR(32)  NOT NULL,
  subgroup_type  VARCHAR(32)  NOT NULL,
  subgroup       VARCHAR(64)  NOT NULL,
  n              INTEGER,                -- distinct students
  suppressed     BOOLEAN      NOT NULL,
  CONSTRAINT program_participation_pk PRIMARY KEY (level, program_id, school_id, subgroup_type, subgroup)
);

-- The single-row district summary a landing page reads. Every column here is
-- also derivable from the marts above, and the pipeline asserts that it agrees
-- with them before the build is allowed to succeed: a headline number that
-- disagrees with the table under it is worse than no headline.
CREATE TABLE gold.district_kpis (
  enrollment            INTEGER      NOT NULL,
  schools_n             INTEGER      NOT NULL,
  ada_pct               DECIMAL(5,1),
  chronic_absent_pct    DECIMAL(5,1),
  ela_proficient_pct    DECIMAL(5,1),
  math_proficient_pct   DECIMAL(5,1),
  grad_4yr_pct_latest   DECIMAL(5,1),
  grad_school_year      VARCHAR(9),             -- the year grad_4yr_pct_latest describes
  tier2_3_pct           DECIMAL(5,1),           -- students receiving targeted support
  interventions_active  INTEGER,
  students_served       INTEGER,                -- distinct students with a service record
  active_partners       INTEGER,
  closed_loop_pct       DECIMAL(5,1),
  computed_at           TIMESTAMP    NOT NULL   -- when the mart was rebuilt, so a
                                                -- reader can tell current from stale
);
