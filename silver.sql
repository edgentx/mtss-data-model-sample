-- Silver layer: typed, deduplicated, one row per business key.
--
-- Illustrative ANSI SQL DDL for the MTSS sample data model (Edgent LLC).
-- In the running platform these tables are Iceberg tables rebuilt by a
-- pipeline that reads a CloudEvents bronze landing zone and keeps the latest
-- event per aggregate; the DDL below states the resulting contract in portable
-- SQL so it can be read, diffed, and reviewed without a warehouse.
--
-- Conventions
--   * school_id is the conformed key across every entity. It is a string
--     identifier, not a surrogate; the district's own building code is the
--     natural key and there is no separate dimension table to drift from it.
--   * school_year is the label form 'YYYY-YY' (for example '2025-26').
--   * grade is a string, not an integer: 'PK3', 'PK4', 'K', '1' .. '12'.
--   * Booleans are stored as booleans, never as 'Y'/'N' strings.
--   * No name, address, date of birth, or contact field appears anywhere in
--     this model. Identity is a pseudonymous student_id; every demographic
--     attribute is a coarse bucket chosen so that gold aggregates over it can
--     clear an N-size threshold.
--
-- This is a SAMPLE. It is not the production schema of any Edgent system and
-- it holds no data from any school district.

CREATE SCHEMA silver;

-- ---------------------------------------------------------------------------
-- Roster and enrollment
-- ---------------------------------------------------------------------------

-- Current-year roster: exactly one row per enrolled student. Every gold
-- subgroup dimension is attributed from THIS record, never from the fact row
-- that carries the measure, so a student's subgroup cannot vary by measure.
CREATE TABLE silver.students (
  student_id      VARCHAR(32)  NOT NULL,  -- pseudonymous stable identifier
  school_id       VARCHAR(32)  NOT NULL,  -- conformed building key
  grade           VARCHAR(4)   NOT NULL,  -- 'PK3','PK4','K','1'..'12'
  gender          VARCHAR(16),            -- coarse bucket
  race_ethnicity  VARCHAR(64),            -- coarse reporting bucket
  ell             BOOLEAN,                -- English language learner
  iep             BOOLEAN,                -- individualized education program
  frpl            BOOLEAN,                -- free or reduced-price lunch
  mtss_tier       SMALLINT     NOT NULL,  -- 1 universal, 2 targeted, 3 intensive
  key_indicator   VARCHAR(32),            -- on_track_college_career |
                                          -- on_track_graduation | at_risk | critical
  CONSTRAINT students_pk PRIMARY KEY (student_id),
  CONSTRAINT students_tier_range CHECK (mtss_tier BETWEEN 1 AND 3)
);

-- Multi-year enrollment history: one row per student per school year. This is
-- the enrollment spine. A student absent from the spine for a year is not
-- "zero attendance" that year, they were not enrolled, and every rate that
-- divides by enrollment reads its denominator here.
CREATE TABLE silver.enrollment_yearly (
  student_id      VARCHAR(32)  NOT NULL,
  school_year     VARCHAR(9)   NOT NULL,  -- 'YYYY-YY'
  school_id       VARCHAR(32)  NOT NULL,
  grade           VARCHAR(4)   NOT NULL,
  gender          VARCHAR(16),
  race_ethnicity  VARCHAR(64),
  ell             BOOLEAN,
  iep             BOOLEAN,
  frpl            BOOLEAN,
  CONSTRAINT enrollment_yearly_pk PRIMARY KEY (student_id, school_year)
);

-- ---------------------------------------------------------------------------
-- Attendance
-- ---------------------------------------------------------------------------

-- One attendance mark per student per school day. School and grade are
-- attributed from the enrollment spine for the mark's school year rather than
-- from the mark itself: a mark's payload can disagree with the roster, and
-- when it does the roster wins.
CREATE TABLE silver.attendance_daily (
  student_id      VARCHAR(32)  NOT NULL,
  attendance_date DATE         NOT NULL,
  school_id       VARCHAR(32)  NOT NULL,  -- from enrollment_yearly
  grade           VARCHAR(4),             -- from enrollment_yearly
  status          VARCHAR(16)  NOT NULL,  -- present | absent | tardy
  CONSTRAINT attendance_daily_pk PRIMARY KEY (student_id, attendance_date),
  CONSTRAINT attendance_daily_status CHECK (status IN ('present','absent','tardy'))
);

-- Monthly attendance rollup carried in silver rather than gold, because the
-- district's source system reports some months only in aggregate. Keeping the
-- grain explicit stops a monthly figure from being mistaken for a sum of daily
-- marks that were never collected.
CREATE TABLE silver.attendance_monthly (
  student_id      VARCHAR(32)  NOT NULL,
  school_year     VARCHAR(9)   NOT NULL,
  month_number    SMALLINT     NOT NULL,  -- calendar month, 1..12
  days_enrolled   SMALLINT     NOT NULL,  -- membership days in the month
  days_present    SMALLINT     NOT NULL,
  CONSTRAINT attendance_monthly_pk PRIMARY KEY (student_id, school_year, month_number),
  CONSTRAINT attendance_monthly_bounds CHECK (days_present BETWEEN 0 AND days_enrolled)
);

-- ---------------------------------------------------------------------------
-- Behavior
-- ---------------------------------------------------------------------------

-- One row per reported behavior incident. Incidents are the trigger for the
-- behavioral intervention domain; silver.interventions.linked_incident_id
-- points back here when a plan was opened because of one.
CREATE TABLE silver.incidents (
  incident_id     VARCHAR(48)  NOT NULL,
  student_id      VARCHAR(32)  NOT NULL,
  school_id       VARCHAR(32)  NOT NULL,
  grade           VARCHAR(4),
  incident_date   DATE         NOT NULL,
  incident_type   VARCHAR(32)  NOT NULL,  -- disruption | insubordination | fighting |
                                          -- harassment | property_damage | other
  location        VARCHAR(32),            -- classroom | hallway | cafeteria | bus | grounds
  disposition     VARCHAR(32),            -- the consequence recorded, including
                                          -- in-school and out-of-school suspension
  CONSTRAINT incidents_pk PRIMARY KEY (incident_id),
  CONSTRAINT incidents_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id)
);

-- ---------------------------------------------------------------------------
-- Assessment
-- ---------------------------------------------------------------------------

-- Universal screening and interim benchmark results from a commercial screener
-- platform. Kept separate from state assessments because the two answer
-- different questions: a screener percentile places a student for instruction,
-- a state proficiency level reports against a standard.
CREATE TABLE silver.benchmarks (
  student_id      VARCHAR(32)  NOT NULL,
  platform        VARCHAR(32)  NOT NULL,  -- screening product the score came from
  subject_area    VARCHAR(32)  NOT NULL,  -- reading | math | early_literacy
  testing_window  VARCHAR(8)   NOT NULL,  -- BOY | MOY | EOY
  school_id       VARCHAR(32)  NOT NULL,
  grade           VARCHAR(4),
  school_year     VARCHAR(9)   NOT NULL,
  percentile      SMALLINT,               -- 1..99 national percentile
  scale_score     INTEGER,
  benchmark_tier  VARCHAR(16),            -- on_benchmark | strategic | intensive
  CONSTRAINT benchmarks_pk PRIMARY KEY (student_id, platform, subject_area, testing_window),
  CONSTRAINT benchmarks_percentile_range CHECK (percentile BETWEEN 1 AND 99)
);

-- State summative assessment results. `family` separates the grade 3-8 program
-- from end-of-course exams so a proficiency rate is never computed across two
-- populations that do not share a denominator.
CREATE TABLE silver.state_assessments (
  student_id      VARCHAR(32)  NOT NULL,
  assessment      VARCHAR(64)  NOT NULL,  -- the specific test administered
  school_year     VARCHAR(9)   NOT NULL,
  school_id       VARCHAR(32)  NOT NULL,
  grade           VARCHAR(4),
  family          VARCHAR(32)  NOT NULL,  -- grades_3_8 | end_of_course
  subject_area    VARCHAR(32)  NOT NULL,  -- ela | math | science | social_studies
  level           SMALLINT,               -- performance level, 1..5
  proficient      BOOLEAN,                -- level at or above the state standard
  CONSTRAINT state_assessments_pk PRIMARY KEY (student_id, assessment, school_year),
  CONSTRAINT state_assessments_level_range CHECK (level BETWEEN 1 AND 5)
);

-- District interim assessments on a vertical scale, two windows per year. This
-- is the table growth analyses read: the same scale in fall and spring makes a
-- within-year gain a subtraction rather than a modeling exercise.
CREATE TABLE silver.assessments (
  student_id      VARCHAR(32)  NOT NULL,
  school_year     VARCHAR(9)   NOT NULL,
  subject         VARCHAR(16)  NOT NULL,  -- ela | math | science
  testing_window  VARCHAR(8)   NOT NULL,  -- fall | spring
  scale_score     INTEGER      NOT NULL,
  proficient      BOOLEAN      NOT NULL,  -- scale_score at or above the cut score
  CONSTRAINT assessments_pk PRIMARY KEY (student_id, school_year, subject, testing_window),
  CONSTRAINT assessments_subject CHECK (subject IN ('ela','math','science'))
);

-- ---------------------------------------------------------------------------
-- Social and emotional learning
-- ---------------------------------------------------------------------------

-- One SEL perception survey response per student per administration per
-- respondent type. `recorded_at` exists because window names do not sort into
-- the order they were given in: 'fall' < 'spring' < 'winter' alphabetically,
-- which is not the school year. Anything comparing administrations over time
-- orders on recorded_at.
CREATE TABLE silver.sel_responses (
  student_id                  VARCHAR(32)  NOT NULL,
  survey_window               VARCHAR(32)  NOT NULL,  -- administration key
  respondent                  VARCHAR(16)  NOT NULL,  -- student | teacher | family
  school_id                   VARCHAR(32)  NOT NULL,
  grade                       VARCHAR(4),
  window_label                VARCHAR(64),            -- reader-facing label
  school_year                 VARCHAR(9)   NOT NULL,
  recorded_at                 TIMESTAMP    NOT NULL,  -- chronological ordering key
  survey_version              SMALLINT,               -- instrument version
  source_system               VARCHAR(32),            -- collecting system
  self_awareness              DECIMAL(3,2),           -- 1.00 .. 5.00
  self_management             DECIMAL(3,2),
  social_awareness            DECIMAL(3,2),
  relationship_skills         DECIMAL(3,2),
  responsible_decision_making DECIMAL(3,2),
  CONSTRAINT sel_responses_pk PRIMARY KEY (student_id, survey_window, respondent)
);

-- ---------------------------------------------------------------------------
-- MTSS interventions
-- ---------------------------------------------------------------------------

-- One intervention plan. The three domains are the whole of the MTSS support
-- model: academic, behavioral, attendance. An aim line is stored as its three
-- parameters (start value, goal value, target date) rather than as a rendered
-- series, so progress can be scored against it at any observation date.
CREATE TABLE silver.interventions (
  intervention_id     VARCHAR(48)  NOT NULL,
  student_id          VARCHAR(32)  NOT NULL,
  school_id           VARCHAR(32)  NOT NULL,
  grade               VARCHAR(4),
  mtss_tier           SMALLINT     NOT NULL,  -- tier the plan was opened at
  domain              VARCHAR(16)  NOT NULL,  -- academic | behavioral | attendance
  strategy            VARCHAR(64),            -- named strategy applied
  educator            VARCHAR(64),            -- responsible staff role or identifier
  goal                VARCHAR(256),           -- the plan's stated goal
  aim_start           DECIMAL(10,2),          -- baseline value on the aim line
  aim_goal            DECIMAL(10,2),          -- target value on the aim line
  aim_target_date     DATE,                   -- date the goal is aimed at
  start_date          DATE         NOT NULL,
  linked_platform     VARCHAR(32),            -- screener that flagged the student
  linked_incident_id  VARCHAR(48),            -- behavior incident that triggered the plan
  auto_flagged        BOOLEAN,                -- opened by a rule, not by a person
  status              VARCHAR(16)  NOT NULL,  -- active | completed | discontinued
  met_goal            BOOLEAN,                -- set only when status = 'completed'
  end_date            DATE,
  CONSTRAINT interventions_pk PRIMARY KEY (intervention_id),
  CONSTRAINT interventions_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id),
  CONSTRAINT interventions_incident_fk FOREIGN KEY (linked_incident_id) REFERENCES silver.incidents (incident_id),
  CONSTRAINT interventions_domain CHECK (domain IN ('academic','behavioral','attendance')),
  CONSTRAINT interventions_status CHECK (status IN ('active','completed','discontinued')),
  CONSTRAINT interventions_tier_range CHECK (mtss_tier BETWEEN 1 AND 3),
  -- met_goal is a claim about a finished plan; an active plan has not met
  -- anything yet, and recording false there would understate effectiveness.
  CONSTRAINT interventions_met_goal_requires_completion
    CHECK (status = 'completed' OR met_goal IS NULL)
);

-- Progress monitoring observations: one per plan per observation date.
-- `on_aim` is stored rather than recomputed at read time so the judgement
-- travels with the observation and cannot be silently re-scored by a later
-- change to the aim line.
CREATE TABLE silver.intervention_progress (
  intervention_id  VARCHAR(48)   NOT NULL,
  observation_date DATE          NOT NULL,
  student_id       VARCHAR(32)   NOT NULL,
  school_id        VARCHAR(32)   NOT NULL,
  domain           VARCHAR(16)   NOT NULL,
  observed_value   DECIMAL(10,2) NOT NULL,
  aim_value        DECIMAL(10,2),           -- the aim line's value on this date
  on_aim           BOOLEAN,                 -- observed_value at or above aim_value
  CONSTRAINT intervention_progress_pk PRIMARY KEY (intervention_id, observation_date),
  CONSTRAINT intervention_progress_fk FOREIGN KEY (intervention_id) REFERENCES silver.interventions (intervention_id)
);

-- ---------------------------------------------------------------------------
-- Community school services
-- ---------------------------------------------------------------------------

-- One community-services referral, carrying its CURRENT status. The status
-- vocabulary is a pipeline, not a flag: a referral moves forward through it and
-- ends in exactly one terminal state.
--
--   Waiting List -> Intake Scheduled -> Service Active -> Service Completed
--   Resource Accessed/Disseminated | Unable to Contact | Closed   (terminal)
--
-- closed_loop is the narrower claim: the referral ended with a CONFIRMED
-- service, which is only 'Service Completed' or 'Resource Accessed/
-- Disseminated'. 'Unable to Contact' and 'Closed' are terminal without being
-- closed-loop, and collapsing the two counts is how a referral pipeline reports
-- success it did not have.
CREATE TABLE silver.referrals (
  referral_id       VARCHAR(48)  NOT NULL,
  student_id        VARCHAR(32)  NOT NULL,
  school_id         VARCHAR(32)  NOT NULL,
  grade             VARCHAR(4),
  partner_id        VARCHAR(32)  NOT NULL,  -- partner organization
  partner_name      VARCHAR(128),
  service_category  VARCHAR(64)  NOT NULL,  -- category of service requested
  opened_date       DATE         NOT NULL,
  current_status    VARCHAR(48)  NOT NULL,  -- see the vocabulary above
  closed_loop       BOOLEAN      NOT NULL,  -- terminal WITH confirmed service
  last_status_date  DATE,                   -- date of the latest status change
  CONSTRAINT referrals_pk PRIMARY KEY (referral_id),
  CONSTRAINT referrals_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id),
  CONSTRAINT referrals_status CHECK (current_status IN (
    'Waiting List','Intake Scheduled','Service Active','Service Completed',
    'Resource Accessed/Disseminated','Unable to Contact','Closed'))
);

-- Every status transition a referral made. Kept as its own table so time in
-- status, and the closed-loop rate over a trailing window, are queries over
-- recorded transitions rather than inferences from a current-state snapshot.
CREATE TABLE silver.referral_events (
  referral_event_id VARCHAR(48)  NOT NULL,
  referral_id       VARCHAR(48)  NOT NULL,
  student_id        VARCHAR(32)  NOT NULL,
  school_id         VARCHAR(32)  NOT NULL,
  partner_id        VARCHAR(32),
  service_category  VARCHAR(64),
  from_status       VARCHAR(48),            -- NULL on the opening transition
  to_status         VARCHAR(48)  NOT NULL,
  event_date        DATE         NOT NULL,
  closed_loop       BOOLEAN      NOT NULL,  -- true when to_status confirms service
  CONSTRAINT referral_events_pk PRIMARY KEY (referral_event_id),
  CONSTRAINT referral_events_fk FOREIGN KEY (referral_id) REFERENCES silver.referrals (referral_id)
);

-- Delivered service sessions: the dosage record behind "was the student
-- actually served, and how much". Sessions and hours are both kept because a
-- count of visits and time on service answer different questions.
CREATE TABLE silver.services (
  service_id        VARCHAR(48)  NOT NULL,
  referral_id       VARCHAR(48),            -- NULL for walk-in service with no referral
  student_id        VARCHAR(32)  NOT NULL,
  school_id         VARCHAR(32)  NOT NULL,
  grade             VARCHAR(4),
  partner_id        VARCHAR(32)  NOT NULL,
  partner_name      VARCHAR(128),
  service_category  VARCHAR(64)  NOT NULL,
  service_date      DATE         NOT NULL,
  sessions          SMALLINT     NOT NULL,  -- sessions delivered on this record
  hours             DECIMAL(6,2) NOT NULL,  -- hours delivered on this record
  CONSTRAINT services_pk PRIMARY KEY (service_id),
  CONSTRAINT services_referral_fk FOREIGN KEY (referral_id) REFERENCES silver.referrals (referral_id),
  CONSTRAINT services_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id)
);

-- ---------------------------------------------------------------------------
-- Graduation and postsecondary readiness
-- ---------------------------------------------------------------------------

-- Completed cohort outcomes, one row per former student. Cohorts are named by
-- entering-ninth-grade year so the four, five, and six year rates are three
-- reads of the same cohort rather than three different populations.
CREATE TABLE silver.grad_outcomes (
  student_id      VARCHAR(32)  NOT NULL,
  cohort_year     SMALLINT     NOT NULL,  -- entering-ninth-grade year
  school_id       VARCHAR(32)  NOT NULL,
  outcome         VARCHAR(24)  NOT NULL,  -- graduated_4yr | graduated_5yr |
                                          -- graduated_6yr | dropout | transferred
  race_ethnicity  VARCHAR(64),
  ell             BOOLEAN,
  iep             BOOLEAN,
  frpl            BOOLEAN,
  CONSTRAINT grad_outcomes_pk PRIMARY KEY (student_id),
  CONSTRAINT grad_outcomes_outcome CHECK (outcome IN (
    'graduated_4yr','graduated_5yr','graduated_6yr','dropout','transferred'))
);

-- Forward-looking graduation tracker for currently enrolled high school
-- students: credits accumulated and exit exams passed against what the state
-- requires. on_track is stored because the requirement set is versioned by
-- cohort, and a recomputation next year would silently re-judge this year.
CREATE TABLE silver.grad_tracker (
  student_id            VARCHAR(32)  NOT NULL,
  school_id             VARCHAR(32)  NOT NULL,
  grade                 VARCHAR(4)   NOT NULL,
  cohort_year           SMALLINT     NOT NULL,
  credits_earned        DECIMAL(5,2) NOT NULL,
  credits_required      DECIMAL(5,2) NOT NULL,
  state_exams_passed    SMALLINT     NOT NULL,  -- required exit exams passed
  state_exams_required  SMALLINT     NOT NULL,
  on_track              BOOLEAN      NOT NULL,  -- judged against this cohort's rules
  CONSTRAINT grad_tracker_pk PRIMARY KEY (student_id),
  CONSTRAINT grad_tracker_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id)
);

-- College and career readiness participation, one row per student.
CREATE TABLE silver.ccr (
  student_id          VARCHAR(32) NOT NULL,
  school_id           VARCHAR(32) NOT NULL,
  grade               VARCHAR(4),
  ap_ib               BOOLEAN     NOT NULL,  -- advanced course participation
  dual_enrollment     BOOLEAN     NOT NULL,  -- college credit while enrolled
  tech_certification  BOOLEAN     NOT NULL,  -- industry certification earned
  CONSTRAINT ccr_pk PRIMARY KEY (student_id),
  CONSTRAINT ccr_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id)
);

-- ---------------------------------------------------------------------------
-- Staff and programs
-- ---------------------------------------------------------------------------

-- Staff roster at the grain the model reports on: role band and building. No
-- individual attribute beyond coarse demographic buckets is carried, because
-- the only published use is a workforce composition figure and a finer grain
-- would make one identifiable.
CREATE TABLE silver.staff (
  staff_id        VARCHAR(32) NOT NULL,
  school_id       VARCHAR(32) NOT NULL,
  role_band       VARCHAR(32) NOT NULL,  -- teacher | teaching_assistant |
                                         -- administrator | support
  grade_band      VARCHAR(16),           -- prek | k12
  gender          VARCHAR(16),
  race_ethnicity  VARCHAR(64),
  school_year     VARCHAR(9)  NOT NULL,
  CONSTRAINT staff_pk PRIMARY KEY (staff_id, school_year)
);

-- Participation in trackable learning initiatives: expanded learning time,
-- advanced coursework, dual enrollment, tutoring, mentoring, summer learning.
CREATE TABLE silver.program_participation (
  student_id     VARCHAR(32)  NOT NULL,
  program_id     VARCHAR(32)  NOT NULL,
  school_year    VARCHAR(9)   NOT NULL,
  school_id      VARCHAR(32)  NOT NULL,
  grade          VARCHAR(4),
  program_name   VARCHAR(128) NOT NULL,
  enrolled_date  DATE,
  CONSTRAINT program_participation_pk PRIMARY KEY (student_id, program_id, school_year),
  CONSTRAINT program_participation_student_fk FOREIGN KEY (student_id) REFERENCES silver.students (student_id)
);
