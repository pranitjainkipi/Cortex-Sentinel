
================================================================================
          CORTEX SENTINEL — DEPLOYMENT PLAN & CODE WALKTHROUGH
================================================================================

This document maps every SQL file in the workspace to its purpose, explains
what each code block does line by line, and provides the exact execution order
needed to deploy Cortex Sentinel from a blank Snowflake account.


================================================================================
 DEPLOYMENT EXECUTION ORDER
================================================================================

  File                          Phase   Run Order
  ---------------------------------------------------------------
  01_infrastructure_and_llm_data.sql    1       FIRST  — Infrastructure + data
  02_deterministic_synthetic_data.sql   1b      SECOND — Deterministic synthetic data
  sentinel_claims_model.yaml            2       THIRD  — Upload to stage (not SQL)
  03_agent_app_dynamic_tables.sql       2+3     FOURTH — Agent, app, dynamic tables

  Total estimated deployment time: 15-25 minutes (excluding compute pool spin-up)


================================================================================
 PHASE 1: INFRASTRUCTURE & DATA FOUNDATION
================================================================================
 File: "01_infrastructure_and_llm_data.sql"
 Purpose: Builds the entire Snowflake infrastructure from scratch, generates
          synthetic data using LLM, creates the knowledge layer, and sets up
          security governance.
================================================================================

SECTION 1: INFRASTRUCTURE SETUP (Lines 1-28)
---------------------------------------------

  USE ROLE ACCOUNTADMIN;
  CREATE WAREHOUSE IF NOT EXISTS SENTINEL_WH ...

  WHAT IT DOES:
  - Switches to ACCOUNTADMIN (highest-privilege role) to create all objects
  - Creates SENTINEL_WH warehouse (MEDIUM size, auto-suspends after 60s of
    idle time, auto-resumes when queries arrive). This is the primary compute
    engine for all claims processing, dynamic tables, and agent queries.
  - Creates SENTINEL_DB database — the central operational database
  - Creates 5 schemas inside SENTINEL_DB:
      CLAIMS    — Core transactional tables (customers, policies, claims)
      KNOWLEDGE — Document storage, parsed text chunks, search services
      MODELS    — Semantic model YAML files for Cortex Analyst
      APPS      — Streamlit app, Cortex Agent, feedback tables
      SECURITY  — Row access policies for governance
  - Creates 4 custom roles with the principle of least privilege:
      SENTINEL_ADMIN     — Full admin access
      SENIOR_ADJUSTER    — Unrestricted claims access
      JUNIOR_ADJUSTER    — Unrestricted claims access
      CALL_CENTER_AGENT  — Restricted to 6 US states only
  - Grants SNOWFLAKE.CORTEX_USER database role to SENTINEL_ADMIN and
    CALL_CENTER_AGENT so they can call Cortex AI functions (COMPLETE,
    AI_CLASSIFY, AI_SENTIMENT, etc.)
  - Creates 3 internal stages with directory listing and SSE encryption:
      @SENTINEL_DB.KNOWLEDGE.DOCS_STAGE    — For uploading PDF policy docs
      @SENTINEL_DB.KNOWLEDGE.AUDIO_STAGE   — For call recording audio files
      @SENTINEL_DB.MODELS.SEMANTIC_STAGE   — For the Cortex Analyst YAML

  WHY THIS ORDER MATTERS:
  Warehouse must exist before any queries. Database and schemas must exist
  before tables. Stages must exist before file uploads.


SECTION 2: TABLE CREATION (Lines 30-90)
----------------------------------------

  CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.CUSTOMERS ...
  CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.POLICIES ...
  CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.CLAIMS ...
  ...

  WHAT IT DOES:
  Creates 8 core tables that form the insurance data model:

  1. CUSTOMERS — Master customer records
     - customer_id (PK), demographics, contact info, segment classification
     - The root entity; everything ties back to a customer

  2. POLICIES — Insurance contracts
     - policy_id (PK), linked to customer_id
     - Stores policy type (AUTO/HOME/COMMERCIAL/WORKERS_COMP/GL), premium,
       coverage limits, deductible, and active/expired/cancelled status

  3. CLAIMS — Insurance claims (the core operational table)
     - claim_no (PK), linked to policy_id and customer_id
     - Tracks the full claim lifecycle: type, status, line of business,
       cause of loss, dates (loss, reported, FNOL completion), location,
       and the assigned adjuster (performer)
     - created_date auto-populates via DEFAULT CURRENT_TIMESTAMP()

  4. CLAIM_LINES — Itemized line items within each claim
     - line_no (PK), linked to claim_no
     - One claim can have multiple repair/expense lines (e.g., bumper
       repair + paint + rental car). Each line has its own status and adjuster.

  5. FINANCIAL_TRANSACTIONS — Money movements on claim lines
     - fxid (PK), linked to line_no
     - Two types: RSV (reserve = money set aside) and PAY (actual payment)
     - This is where dollar amounts live. Currency defaults to USD.

  6. INVOICES — Vendor bills for claim work 
     - Links to claim_lines via line_no
     - Ready for future vendor management functionality

  7. AUTHORIZATION — Adjuster payment limits (schema only)
     - performer_id (PK), from_amt/to_amt define the dollar range an
       adjuster can approve without escalation
     - Used by the COMPLIANCE_ALERTS dynamic table to auto-detect violations

  8. CALL_TRANSCRIPTS — Customer call center conversations
     - transcript_id (PK), linked to claim_no and customer_id
     - Stores full transcript text, AI-enriched sentiment and intent,
       call duration, and which agent handled the call


SECTION 3: LLM-GENERATED SYNTHETIC DATA (Lines 92-337)
-------------------------------------------------------

  INSERT INTO SENTINEL_DB.CLAIMS.CUSTOMERS AS
  WITH raw AS (
      SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', ...) AS raw_response
  ), ...

  WHAT IT DOES:
  Uses Snowflake Cortex COMPLETE (llama3.1-70b model) to generate realistic
  synthetic data. This is the "AI data factory" pattern:

  For each table (CUSTOMERS, POLICIES, CLAIMS, CLAIM_LINES,
  FINANCIAL_TRANSACTIONS, CALL_TRANSCRIPTS), the same 4-step CTE pattern
  is used:

    Step 1 (raw): Calls CORTEX.COMPLETE with a detailed prompt describing
    the exact JSON schema needed. Uses the object-form COMPLETE API
    (array of messages) to set max_tokens=4096 and temperature=0.7 for
    creative but realistic output.

    Step 2 (extracted): Navigates the Cortex response JSON structure
    (raw_response:choices[0]:messages) to extract the raw JSON string
    from the model's reply.

    Step 3 (cleaned): Strips any markdown code fences (```json ... ```)
    the LLM may have added, leaving clean JSON.

    Step 4 (final SELECT): Uses TRY_PARSE_JSON to safely parse the
    cleaned string, then LATERAL FLATTEN to explode the JSON array into
    individual rows, casting each field to the correct Snowflake type.

  WHY TRY_PARSE_JSON: If the LLM returns malformed JSON, TRY_PARSE_JSON
  returns NULL instead of failing, making the pipeline more resilient.

  DATA VOLUMES GENERATED:
    50 customers, 80 policies, 100 claims, 150 claim lines,
    200 financial transactions, 30 call transcripts


SECTION 4: KNOWLEDGE LAYER — DOCUMENT INGESTION (Lines 339-417)
----------------------------------------------------------------

  CREATE OR REPLACE PROCEDURE SENTINEL_DB.KNOWLEDGE.GENERATE_POLICY_DOCS()
  ...

  WHAT IT DOES:
  This section builds the unstructured data pipeline in 5 steps:

  Step 4a: GENERATE_POLICY_DOCS stored procedure
    - Written in Python (Snowpark) running on Python 3.11
    - Reads 10 policies from the database
    - For each policy, calls CORTEX.COMPLETE to generate a realistic
      insurance policy document (declarations, coverage, exclusions)
    - Inserts the generated text into PARSED_GUIDELINES table
    - This simulates what would normally come from PDF document parsing

  Step 4b: PDF parsing (for real documents)
    - If actual PDFs are uploaded to @DOCS_STAGE, this INSERT uses
      AI_PARSE_DOCUMENT with LAYOUT mode to extract text content
    - AI_PARSE_DOCUMENT is a Cortex function that performs OCR + layout
      analysis on PDF/image files, returning structured text
    - The :content accessor extracts just the text from the parse result

  Step 4c: Text chunking for GUIDELINES_CHUNKS
    - Uses SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER to break long
      document text into overlapping chunks
    - Parameters: 1500 chars per chunk, 200 char overlap
    - The overlap ensures context is not lost at chunk boundaries
    - Uses 'markdown' as the split mode (respects markdown structure)
    - LATERAL FLATTEN converts the array of chunks into rows

  Step 4d: Text chunking for NOTES_CHUNKS
    - Same pattern as guidelines, but for claim-specific notes
    - Adds claim_no as an attribute so search can filter by claim

  Step 4e: Cortex Search Services
    - GUIDELINES_SEARCH: Creates a vector search index over guideline chunks
      using snowflake-arctic-embed-l-v2.0 embeddings. Refreshes hourly.
      Returns filename as an attribute for source citation.
    - CLAIM_NOTES_SEARCH: Same pattern for claim notes, with claim_no
      as an additional attribute for claim-specific filtering.
    - These become tools that the Cortex Agent can invoke.


SECTION 5: AI ENRICHMENT OF CALL TRANSCRIPTS (Lines 446-483)
-------------------------------------------------------------

  INSERT INTO SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS ...
  UPDATE SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS SET ...

  WHAT IT DOES:
  Two-step AI enrichment pipeline:

  Step 5a: Generate additional transcripts (if needed)
    - For each claim, generates a realistic 3-minute conversation using
      CORTEX.COMPLETE, varying the customer emotion (frustration/concern)
    - Randomizes call timing (1-72 hours after reported_date), duration
      (120-600 seconds), and agent assignment

  Step 5b: Enrich ALL transcripts with AI analysis
    - AI_SENTIMENT: Analyzes each transcript for sentiment across 3
      dimensions (Claims Process, Agent Professionalism, Resolution
      Satisfaction). Returns a composite sentiment score.
    - AI_CLASSIFY: Classifies the intent of each call into one of 6
      categories (FNOL Report, Status Inquiry, Payment Question,
      Complaint, Document Submission, Policy Question).
    - Uses UPDATE (not INSERT) to enrich existing rows in-place.


SECTION 6: ROW ACCESS POLICIES (Lines 486-507)
-----------------------------------------------

  CREATE OR REPLACE ROW ACCESS POLICY SENTINEL_DB.SECURITY.RAP_CLAIMS_TIER
  ...

  WHAT IT DOES:
  Implements row-level security on the CLAIMS table:

  Step 6a: Drops any existing policy attachment (to avoid conflicts)
  Step 6b: Creates the policy with role-based logic:
    - ACCOUNTADMIN, SENTINEL_ADMIN, SENIOR_ADJUSTER, JUNIOR_ADJUSTER
      → can see ALL claims in ALL states
    - CALL_CENTER_AGENT → can ONLY see claims where loss_state is in
      (CA, TX, FL, NY, OR, WA)
    - Uses IS_ROLE_IN_SESSION() which checks the user's active role
      hierarchy (not just direct role assignment)
  Step 6c: Attaches the policy to CLAIMS table on the loss_state column

  EFFECT: When a CALL_CENTER_AGENT queries the CLAIMS table, rows from
  non-authorized states are silently filtered out. The user never sees
  them and doesn't know they exist. This is transparent row-level security.


================================================================================
 PHASE 1b: DETERMINISTIC SYNTHETIC DATA (BACKUP/REPLACEMENT)
================================================================================
 File: "02_deterministic_synthetic_data.sql"
 Purpose: Provides hand-crafted, deterministic INSERT statements as a
          reliable alternative to the LLM-generated data. Use this if the
          LLM output from Phase 1 was incomplete or malformed.
================================================================================

  WHAT IT DOES:
  Contains explicit VALUES lists for all tables:

  1. POLICIES (80 rows, Lines 12-95)
     - 80 hand-written policy records with realistic premium/coverage combos
     - Covers all 5 policy types, all 4 statuses
     - Some customers have multiple policies (e.g., CUST-001 has both
       AUTO and HOME)

  2. CLAIMS (100 rows, Lines 100-205)
     - 100 claim records with varied scenarios (collisions, water damage,
       theft, fire, slip-and-fall, vandalism, liability)
     - Uses all 5 claim statuses and all 6 US states
     - 20 adjusters (ADJ-101 through ADJ-120) distributed across claims
     - Loss descriptions are unique and realistic for each claim

  3. CLAIM_LINES (150 rows, Lines 210-363)
     - 1-3 lines per claim, representing individual repair/expense items
     - Each line has its own adjuster assignment and status

  4. FINANCIAL_TRANSACTIONS (200 rows, Lines 368-571)
     - Mix of RSV (reserves) and PAY (payments) transactions
     - Reserves are always set first, payments follow
     - Amounts range from $500 to $75,000

  5. CALL_TRANSCRIPTS (30 rows, Lines 576-609)
     - Full conversational transcripts between agents and customers
     - Pre-filled sentiment (POSITIVE/NEGATIVE/NEUTRAL/FRUSTRATED)
     - Pre-filled intent (FILE_CLAIM/CLAIM_STATUS/DISPUTE/PAYMENT_INQUIRY
       /DOCUMENT_REQUEST)
     - Each transcript is 3-6 dialogue exchanges

  WHY THIS FILE EXISTS:
  LLM-generated data (Phase 1) is non-deterministic — running it twice
  gives different results, and the LLM may produce malformed JSON or
  fewer rows than requested. This file provides a deterministic fallback
  that guarantees exact data volumes and referential integrity.

  DEPLOYMENT NOTE: Run EITHER the LLM inserts from "setup and synthetic
  data.sql" OR the deterministic inserts from "Untitled.sql" — NOT both
  (they would create duplicate primary key conflicts).


================================================================================
 PHASE 2: SEMANTIC MODEL
================================================================================
 File: "sentinel_claims_model.yaml"
 Purpose: Defines the structured data contract for Cortex Analyst, enabling
          natural language to SQL translation.
================================================================================

  WHAT IT DOES:
  This YAML file is NOT executed as SQL. It is uploaded to a Snowflake
  stage and referenced by the Cortex Agent's ClaimsAnalyst tool.

  UPLOAD COMMAND:
    PUT file://sentinel_claims_model.yaml @SENTINEL_DB.MODELS.SEMANTIC_STAGE;

  STRUCTURE:

  1. HEADER (Lines 1-4)
     - name: sentinel_claims_analysis
     - description: Tells Cortex Analyst what domain this model covers

  2. TABLES (Lines 6-201)
     Four tables are modeled, each with:

     a. claims table:
        - 6 dimensions: claim_no, claim_status, line_of_business,
          cause_of_loss, loss_state, performer
        - 2 time dimensions: loss_date, reported_date
        - 2 filters: open_claims, closed_claims (pre-built WHERE clauses)
        - 2 metrics: claim_count (COUNT DISTINCT), average_days_to_report
        - synonyms: Alternative names users might say, e.g., "LOB" for
          line_of_business, "adjuster" for performer
        - is_enum: true tells Analyst to treat values as categorical
        - sample_values: Helps Analyst generate valid WHERE clauses

     b. claim_lines table:
        - 4 dimensions: line_no, claim_no, line_status, performer_id
        - 1 time dimension: line_created_date

     c. financial_transactions table:
        - 1 dimension: financial_type (RSV/PAY)
        - 1 time dimension: transaction_date
        - 1 fact: transaction_amount (the actual dollar value)
        - 3 metrics: total_paid, total_reserves, total_incurred
          Each uses CASE WHEN to filter by financial_type

     d. policies table:
        - 3 dimensions: policy_id, policy_type, status
        - 1 fact: annual_premium
        - 2 metrics: total_premium, policy_count

  3. RELATIONSHIPS (Lines 203-219)
     Defines how tables join together:
       claims.POLICY_ID = policies.POLICY_ID
       claim_lines.CLAIM_NO = claims.CLAIM_NO
       financial_transactions.LINE_NO = claim_lines.LINE_NO
     This lets Analyst automatically generate multi-table JOINs when
     users ask cross-table questions.

  4. GLOBAL METRICS (Lines 221-228)
     loss_ratio = total_incurred / total_premium
     This cross-table metric references metrics from two different tables.

  5. VERIFIED QUERIES (Lines 230-281)
     4 pre-validated SQL queries that Cortex Analyst uses as examples:
       - Monthly claims count this year
       - Top 10 states by total incurred losses
       - Open claims by line of business
       - Loss ratio by line of business
     The __tablename syntax is a placeholder that Analyst replaces with
     the actual fully qualified table name at runtime.
     use_as_onboarding_question: true makes these appear as suggested
     questions in the UI.


================================================================================
 PHASE 2+3: INTELLIGENCE LAYER & SOVEREIGN DECISION ENGINE
================================================================================
 File: "03_agent_app_dynamic_tables.sql"
 Purpose: Creates the AI agent, custom tools, Streamlit app, dynamic tables,
          streaming simulation, compliance monitoring, and feedback loop.
================================================================================

SECTION A: CUSTOM AI TOOLS (Lines 291-324)
-------------------------------------------

  CREATE OR REPLACE FUNCTION SENTINEL_DB.CLAIMS.CLASSIFY_DOCUMENT(...)
  CREATE OR REPLACE FUNCTION SENTINEL_DB.CLAIMS.ASSESS_FRAUD_RISK(...)

  WHAT THEY DO:

  1. CLASSIFY_DOCUMENT (UDF)
     - Input: doc_text (VARCHAR) — the text content of any document
     - Calls AI_CLASSIFY with 6 predefined labels:
       Insurance Claim Form, Medical Bill, Invoice, Police Report,
       Policy Document, Correspondence
     - Each label has a description to help the classifier
     - Returns: OBJECT with the classified label and confidence score
     - USE CASE: When a user uploads a document to the system, this
       function auto-categorizes it for routing

  2. ASSESS_FRAUD_RISK (UDF)
     - Input: claim_details (VARCHAR) — free-text description of a claim
     - Calls CORTEX.COMPLETE (claude-4-sonnet) with a system prompt that
       instructs the model to act as a fraud analyst
     - Returns: OBJECT with {risk_score: 1-10, red_flags: [...],
       recommendation: approve|investigate|deny, reasoning: "..."}
     - Temperature set to 0.1 for deterministic, conservative output
     - max_tokens: 500 keeps responses concise
     - USE CASE: Agent calls this when a user asks "Is this claim
       suspicious?" or "Assess fraud risk for CLM-00042"


SECTION B: CORTEX AGENT CREATION (Lines 330-446)
-------------------------------------------------

  CREATE OR REPLACE AGENT SENTINEL_DB.APPS.CORTEX_SENTINEL_AGENT ...

  WHAT IT DOES:
  This is the centerpiece of the entire project. It creates a Cortex Agent
  that orchestrates 6 different tools to answer any insurance question.

  CONFIGURATION:
    - models.orchestration: auto — Snowflake picks the best model
    - budget.seconds: 45 — Maximum time per response
    - budget.tokens: 20000 — Maximum tokens per response

  INSTRUCTIONS SECTION:
    system: Defines the agent's 3 personas:
      1. COMPLIANCE OFFICER — audits, authorization checks, anomalies
      2. UNDERWRITER — financial analysis, loss ratios, risk assessment
      3. LIBRARIAN — document search, policy interpretation

    orchestration: Rules for which tool to use when:
      - Quantitative questions → ClaimsAnalyst (text-to-SQL)
      - Policy/coverage questions → GuidelinesSearch
      - Claim-specific history → ClaimNotesSearch
      - Document classification → DocumentClassifier
      - Fraud questions → FraudAssessor
      - Visualizations → data_to_chart (after getting data)

    sample_questions: 4 example Q&A pairs that help the agent understand
    the expected interaction pattern.

  TOOLS (6 total):

    Tool 1: ClaimsAnalyst (cortex_analyst_text_to_sql)
      - Connected to the semantic model YAML on stage
      - Converts natural language → SQL → executes → returns results
      - Runs on SENTINEL_WH with 60s query timeout

    Tool 2: GuidelinesSearch (cortex_search)
      - Connected to GUIDELINES_SEARCH service
      - Returns top 5 matching document chunks
      - Uses filename as the title for citations

    Tool 3: ClaimNotesSearch (cortex_search)
      - Connected to CLAIM_NOTES_SEARCH service
      - Returns top 5 matching note chunks
      - Uses filename as title, also returns claim_no

    Tool 4: DocumentClassifier (generic)
      - Calls CLASSIFY_DOCUMENT UDF
      - Runs on SENTINEL_WH with 30s timeout

    Tool 5: FraudAssessor (generic)
      - Calls ASSESS_FRAUD_RISK UDF
      - Runs on SENTINEL_WH with 30s timeout

    Tool 6: data_to_chart (data_to_chart)
      - Built-in Snowflake tool that generates Vega-Lite chart specs
      - Used after ClaimsAnalyst returns data to create visualizations


SECTION C: STREAMLIT APPLICATION (Lines 451-473)
-------------------------------------------------

  CREATE COMPUTE POOL IF NOT EXISTS SENTINEL_POOL ...
  CREATE STREAMLIT SENTINEL_DB.APPS.CORTEX_SENTINEL_APP ...

  WHAT IT DOES:

  1. Creates SENTINEL_POOL compute pool:
     - INSTANCE_FAMILY: CPU_X64_XS (smallest CPU instance)
     - MIN_NODES: 1, MAX_NODES: 2 (auto-scales between 1-2 nodes)
     - Required because the Streamlit app uses Container Runtime
       (needed for Cortex Agent API access)

  2. Creates the Streamlit app:
     - RUNTIME_NAME: SYSTEM$ST_CONTAINER_RUNTIME_PY3_11 (Python 3.11
       container with full pip access)
     - COMPUTE_POOL: SENTINEL_POOL (where the container runs)
     - QUERY_WAREHOUSE: SENTINEL_WH (for SQL queries from the app)

  NOTE: The actual Python code for the Streamlit app is written in the
  Snowflake Streamlit editor (not in this SQL file). The SQL only creates
  the app object and compute infrastructure.
  DATA_AGENT_RUN returns: "Access denied for trial accounts." 
  — This is the root cause of your app not returning data.


SECTION D: STREAMING SIMULATION (Lines 476-553)
------------------------------------------------

  CREATE OR REPLACE PROCEDURE SENTINEL_DB.CLAIMS.SIMULATE_NEW_CLAIMS(...)
  CREATE TASK SENTINEL_DB.CLAIMS.STREAMING_SIMULATOR ...

  WHAT IT DOES:

  1. SIMULATE_NEW_CLAIMS procedure:
     - Takes batch_size parameter (number of claims to generate)
     - Picks random ACTIVE policies using ORDER BY RANDOM() LIMIT
     - Generates a claim for each with:
       - UUID_STRING() for unique claim numbers
       - Random cause_of_loss from 5 options via ARRAY_CONSTRUCT + UNIFORM
       - Random loss_state from 6 states
       - Loss date within the last 30 days
       - Random adjuster assignment (ADJ-1 through ADJ-15)
     - This simulates real-time FNOL (First Notice of Loss) arriving

  2. STREAMING_SIMULATOR task:
     - Runs on SENTINEL_WH every 2 minutes
     - Calls SIMULATE_NEW_CLAIMS(5) — inserts 5 new claims per cycle
     - ALTER TASK ... RESUME starts the task
     - Combined with Dynamic Tables, this creates the illusion of a
       live streaming pipeline without needing Snowpipe Streaming's
       Java SDK

  WHY THIS MATTERS:
  This is what makes the CUSTOMER_360 and CLAIMS_SEVERITY_MAP dynamic
  tables come alive — they auto-refresh as new claims flow in.


SECTION E: DYNAMIC TABLES (Lines 517-553)
------------------------------------------

  CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.CLAIMS.CUSTOMER_360 ...
  CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.CLAIMS.CLAIMS_SEVERITY_MAP ...

  WHAT THEY DO:

  1. CUSTOMER_360 (5-minute lag):
     - Joins CUSTOMERS + POLICIES + CLAIMS
     - Aggregates per customer: active_policies, total_premium,
       total_claims, open_claims, last_claim_date, days_since_last_claim
     - Updates automatically every 5 minutes
     - Powers the customer dashboard in the Streamlit app

  2. CLAIMS_SEVERITY_MAP (5-minute lag):
     - Joins CLAIMS + FINANCIAL_TRANSACTIONS
     - Groups by loss_state and line_of_business
     - Calculates claim_count, total_incurred, avg_severity, open_count
     - Powers the severity heatmap visualization


SECTION F: COMPLIANCE ALERTS (Lines 566-581)
---------------------------------------------

  CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.CLAIMS.COMPLIANCE_ALERTS ...

  WHAT IT DOES:
  Auto-detects authorization limit violations (10-minute lag):
  - Joins CLAIMS → CLAIM_LINES → FINANCIAL_TRANSACTIONS → AUTHORIZATION
  - Filters for PAY transactions where fin_tx_amt > authorization to_amt
  - Tags each match as 'OVER_LIMIT'
  - This is the "Compliance Officer" persona's automated monitoring

  EXAMPLE: If ADJ-101 is authorized up to $10,000 but processes a
  $15,000 payment, this dynamic table automatically flags it.


SECTION G: FEEDBACK LOOP (Lines 587-608)
-----------------------------------------

  CREATE TABLE SENTINEL_DB.APPS.AGENT_FEEDBACK ...
  CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.APPS.AGENT_PERFORMANCE ...

  WHAT IT DOES:

  1. AGENT_FEEDBACK table:
     - Stores user ratings of agent responses
     - feedback_id auto-generates via UUID_STRING()
     - Tracks: the question asked, the agent's response text,
       whether the user rated it positive (boolean), optional notes
     - Populated by the Streamlit app's thumbs-up/down buttons

  2. AGENT_PERFORMANCE dynamic table (30-minute lag):
     - Aggregates feedback by day
     - Calculates satisfaction_pct = positive / total * 100
     - Powers the agent performance dashboard
     - Enables continuous improvement tracking


================================================================================
 DEPLOYMENT CHECKLIST
================================================================================

  STEP  ACTION                                         FILE                    TIME
  ----  -------------------------------------------    --------------------    ----
  1     Set role to ACCOUNTADMIN                       setup and synthetic     0m
  2     Create warehouse SENTINEL_WH                   setup and synthetic     10s
  3     Create database and 5 schemas                  setup and synthetic     10s
  4     Create 4 custom roles + Cortex grants          setup and synthetic     10s
  5     Create 3 internal stages                       setup and synthetic     10s
  6     Create 8 base tables                           setup and synthetic     10s
  7a    Generate data with LLM (Option A)              setup and synthetic     5-10m
  7b    OR insert deterministic data (Option B)        Untitled.sql            30s
  8     Create GENERATE_POLICY_DOCS procedure          setup and synthetic     10s
  9     Create PARSED_GUIDELINES + PARSED_CLAIM_NOTES  setup and synt
