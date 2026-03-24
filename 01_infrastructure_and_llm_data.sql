-- Account and database setup
USE ROLE ACCOUNTADMIN;
CREATE WAREHOUSE IF NOT EXISTS SENTINEL_WH 
  WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;
  
CREATE DATABASE IF NOT EXISTS SENTINEL_DB;
CREATE SCHEMA IF NOT EXISTS SENTINEL_DB.CLAIMS;
CREATE SCHEMA IF NOT EXISTS SENTINEL_DB.KNOWLEDGE;
CREATE SCHEMA IF NOT EXISTS SENTINEL_DB.MODELS;
CREATE SCHEMA IF NOT EXISTS SENTINEL_DB.APPS;
CREATE SCHEMA IF NOT EXISTS SENTINEL_DB.SECURITY;-- Roles
CREATE ROLE IF NOT EXISTS SENTINEL_ADMIN;
CREATE ROLE IF NOT EXISTS SENIOR_ADJUSTER;
CREATE ROLE IF NOT EXISTS JUNIOR_ADJUSTER;
CREATE ROLE IF NOT EXISTS CALL_CENTER_AGENT;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SENTINEL_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CALL_CENTER_AGENT;

-- Internal stages for unstructured data
CREATE STAGE IF NOT EXISTS SENTINEL_DB.KNOWLEDGE.DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
  
CREATE STAGE IF NOT EXISTS SENTINEL_DB.KNOWLEDGE.AUDIO_STAGE
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
  
CREATE STAGE IF NOT EXISTS SENTINEL_DB.MODELS.SEMANTIC_STAGE
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');


CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.CUSTOMERS (
    customer_id       VARCHAR PRIMARY KEY,
    first_name        VARCHAR, last_name VARCHAR,
    email             VARCHAR, phone VARCHAR,
    address           VARCHAR, city VARCHAR, state VARCHAR, zip_code VARCHAR,
    date_of_birth     DATE, segment VARCHAR,
    customer_since    DATE, preferred_contact VARCHAR
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.POLICIES (
    policy_id         VARCHAR PRIMARY KEY,
    customer_id       VARCHAR ,
    policy_type       VARCHAR,-- AUTO, HOME, COMMERCIAL, WORKERS_COMP, GL
    effective_date    DATE, expiration_date DATE,
    annual_premium    NUMBER(12,2), coverage_limit NUMBER(12,2),
    deductible        NUMBER(12,2), status VARCHAR
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.CLAIMS (
    claim_no          VARCHAR PRIMARY KEY,
    policy_id         VARCHAR ,
    customer_id       VARCHAR ,
    claim_type        VARCHAR, claim_status VARCHAR,
    line_of_business  VARCHAR, cause_of_loss VARCHAR,
    loss_description  VARCHAR, loss_date DATE,
    reported_date     DATE, fnol_completion_date DATE,
    loss_state        VARCHAR, loss_zip_code VARCHAR,
    performer         VARCHAR, claimant_id VARCHAR,
    created_date      TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.CLAIM_LINES (
    line_no           VARCHAR PRIMARY KEY,
    claim_no          VARCHAR ,
    loss_description  VARCHAR, claim_status VARCHAR,
    performer_id      VARCHAR,
    created_date      TIMESTAMP, reported_date DATE
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.FINANCIAL_TRANSACTIONS (
    fxid              VARCHAR PRIMARY KEY,
    line_no           VARCHAR ,
    financial_type    VARCHAR,-- RSV (reserve), PAY (payment)
    currency          VARCHAR DEFAULT 'USD',
    fin_tx_amt        NUMBER(12,2),
    fin_tx_post_dt    DATE
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.INVOICES (
    inv_id            VARCHAR, inv_line_nbr NUMBER,
    line_no           VARCHAR, description VARCHAR,
    currency          VARCHAR, vendor VARCHAR,
    invoice_date      DATE, invoice_amount NUMBER(12,2)
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.AUTHORIZATION (
    performer_id      VARCHAR PRIMARY KEY,
    currency          VARCHAR, from_amt NUMBER(12,2), to_amt NUMBER(12,2)
);
CREATE OR REPLACE TABLE SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS (
    transcript_id     VARCHAR PRIMARY KEY,
    claim_no          VARCHAR, customer_id VARCHAR,
    call_date         TIMESTAMP, caller_type VARCHAR,
   transcript_text   VARCHAR, sentiment VARCHAR,
    intent            VARCHAR, duration_seconds NUMBER,
    agent_id          VARCHAR
);

SELECT SNOWFLAKE.CORTEX.COMPLETE(
'llama3.1-70b',
'Generate 50 realistic insurance customers as a JSON array. Each object:
         {"customer_id":"CUST-001","first_name":"Jane","last_name":"Smith",
          "email":"jane@email.com","phone":"503-555-1234",
          "address":"123 Oak St","city":"Portland","state":"OR","zip_code":"9720
          "date_of_birth":"1985-03-15","segment":"Premium",
          "customer_since":"2019-06-01","preferred_contact":"email"}.
         Vary names, states (focus on CA, TX, FL, NY, OR, WA), realistic dates.
         Return ONLY the JSON array, no other text.'
) AS raw_json;

-- Generate synthetic customers (use object-form COMPLETE to set max_tokens high enough for 50 records)
INSERT INTO  SENTINEL_DB.CLAIMS.CUSTOMERS AS
WITH raw AS (
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        [{'role':'user','content':'Generate 50 realistic insurance customers as a JSON array. Each object: 
         {"customer_id":"CUST-001","first_name":"Jane","last_name":"Smith",
          "email":"jane@email.com","phone":"503-555-1234",
          "address":"123 Oak St","city":"Portland","state":"OR","zip_code":"97201",
          "date_of_birth":"1985-03-15","segment":"Premium",
          "customer_since":"2019-06-01","preferred_contact":"email"}.
         Vary names, states (focus on CA, TX, FL, NY, OR, WA), realistic dates.
         Return ONLY the pure JSON array. No explanation, no markdown, no code fences.'}],
        {'max_tokens': 4096, 'temperature': 0.7}
    ) AS raw_response
),
extracted AS (
    SELECT raw_response:choices[0]:messages::VARCHAR AS raw_json
    FROM raw
),
cleaned AS (
    SELECT 
        TRIM(REPLACE(REPLACE(raw_json, '```json', ''), '```', '')) AS clean_json
    FROM extracted
)
SELECT 
    f.value:customer_id::VARCHAR AS customer_id,
    f.value:first_name::VARCHAR AS first_name,
    f.value:last_name::VARCHAR AS last_name,
    f.value:email::VARCHAR AS email,
    f.value:phone::VARCHAR AS phone,
    f.value:address::VARCHAR AS address,
    f.value:city::VARCHAR AS city,
    f.value:state::VARCHAR AS state,
    f.value:zip_code::VARCHAR AS zip_code,
    f.value:date_of_birth::DATE AS date_of_birth,
    f.value:segment::VARCHAR AS segment,
    f.value:customer_since::DATE AS customer_since,
    f.value:preferred_contact::VARCHAR AS preferred_contact
FROM cleaned, LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(clean_json)) f;

;
select * from SENTINEL_DB.CLAIMS.CUSTOMERS;

-- Generate synthetic policies
INSERT INTO SENTINEL_DB.CLAIMS.POLICIES
WITH raw AS (
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        [{'role':'user','content':'Generate 80 realistic insurance policies as a JSON array. 
         Use customer_ids CUST-001 through CUST-050.
         Each object:
         {"policy_id":"POL-0001","customer_id":"CUST-003","policy_type":"AUTO",
          "effective_date":"2023-01-15","expiration_date":"2024-01-15",
          "annual_premium":1250.00,"coverage_limit":100000.00,
          "deductible":500.00,"status":"ACTIVE"}.
         policy_type must be one of: AUTO, HOME, COMMERCIAL, WORKERS_COMP, GL.
         status must be one of: ACTIVE, EXPIRED, CANCELLED, PENDING.
         Mix customers so some have multiple policies. Realistic premiums and limits.
         Return ONLY the pure JSON array. No explanation, no markdown, no code fences.'}],
        {'max_tokens': 4096, 'temperature': 0.7}
    ) AS raw_response
),
extracted AS (
    SELECT raw_response:choices[0]:messages::VARCHAR AS raw_json FROM raw
),
cleaned AS (
    SELECT TRIM(REPLACE(REPLACE(raw_json, '```json', ''), '```', '')) AS clean_json FROM extracted
)
SELECT 
    f.value:policy_id::VARCHAR,
    f.value:customer_id::VARCHAR,
    f.value:policy_type::VARCHAR,
    f.value:effective_date::DATE,
    f.value:expiration_date::DATE,
    f.value:annual_premium::NUMBER(12,2),
    f.value:coverage_limit::NUMBER(12,2),
    f.value:deductible::NUMBER(12,2),
    f.value:status::VARCHAR
FROM cleaned, LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(clean_json)) f;

-- Generate synthetic claims
INSERT INTO SENTINEL_DB.CLAIMS.CLAIMS
WITH raw AS (
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        [{'role':'user','content':'Generate 100 realistic insurance claims as a JSON array.
         Use policy_ids POL-0001 through POL-0080 and customer_ids CUST-001 through CUST-050.
         Each object:
         {"claim_no":"CLM-00001","policy_id":"POL-0012","customer_id":"CUST-007",
          "claim_type":"FIRST_PARTY","claim_status":"OPEN",
          "line_of_business":"AUTO","cause_of_loss":"COLLISION",
          "loss_description":"Rear-end collision at intersection causing bumper and trunk damage",
          "loss_date":"2024-06-15","reported_date":"2024-06-16",
          "fnol_completion_date":"2024-06-16",
          "loss_state":"CA","loss_zip_code":"90210",
          "performer":"ADJ-101","claimant_id":"CLMT-001"}.
         claim_status: OPEN, CLOSED, PENDING_REVIEW, DENIED, UNDER_INVESTIGATION.
         cause_of_loss: COLLISION, THEFT, FIRE, WATER_DAMAGE, WIND, LIABILITY, SLIP_AND_FALL, VANDALISM.
         line_of_business: AUTO, HOME, COMMERCIAL, WORKERS_COMP, GL.
         Vary loss descriptions realistically. 
         Return ONLY the pure JSON array. No explanation, no markdown, no code fences.'}],
        {'max_tokens': 4096, 'temperature': 0.7}
    ) AS raw_response
),
extracted AS (
    SELECT raw_response:choices[0]:messages::VARCHAR AS raw_json FROM raw
),
cleaned AS (
    SELECT TRIM(REPLACE(REPLACE(raw_json, '```json', ''), '```', '')) AS clean_json FROM extracted
)
SELECT 
    f.value:claim_no::VARCHAR,
    f.value:policy_id::VARCHAR,
    f.value:customer_id::VARCHAR,
    f.value:claim_type::VARCHAR,
    f.value:claim_status::VARCHAR,
    f.value:line_of_business::VARCHAR,
    f.value:cause_of_loss::VARCHAR,
    f.value:loss_description::VARCHAR,
    f.value:loss_date::DATE,
    f.value:reported_date::DATE,
    f.value:fnol_completion_date::DATE,
    f.value:loss_state::VARCHAR,
    f.value:loss_zip_code::VARCHAR,
    f.value:performer::VARCHAR,
    f.value:claimant_id::VARCHAR,
    CURRENT_TIMESTAMP()
FROM cleaned, LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(clean_json)) f;

-- Generate synthetic claim lines
INSERT INTO SENTINEL_DB.CLAIMS.CLAIM_LINES
WITH raw AS (
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        [{'role':'user','content':'Generate 150 realistic insurance claim lines as a JSON array.
         Use claim_nos CLM-00001 through CLM-00100. Some claims have multiple lines.
         Each object:
         {"line_no":"LN-000001","claim_no":"CLM-00005",
          "loss_description":"Front bumper replacement and paint",
          "claim_status":"OPEN","performer_id":"ADJ-101",
          "created_date":"2024-06-16T10:30:00","reported_date":"2024-06-16"}.
         claim_status: OPEN, CLOSED, PENDING_REVIEW, DENIED.
         Vary performer_ids ADJ-101 through ADJ-120.
         Return ONLY the pure JSON array. No explanation, no markdown, no code fences.'}],
        {'max_tokens': 4096, 'temperature': 0.7}
    ) AS raw_response
),
extracted AS (
    SELECT raw_response:choices[0]:messages::VARCHAR AS raw_json FROM raw
),
cleaned AS (
    SELECT TRIM(REPLACE(REPLACE(raw_json, '```json', ''), '```', '')) AS clean_json FROM extracted
)
SELECT 
    f.value:line_no::VARCHAR,
    f.value:claim_no::VARCHAR,
    f.value:loss_description::VARCHAR,
    f.value:claim_status::VARCHAR,
    f.value:performer_id::VARCHAR,
    f.value:created_date::TIMESTAMP,
    f.value:reported_date::DATE
FROM cleaned, LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(clean_json)) f;

-- Generate synthetic financial transactions
INSERT INTO SENTINEL_DB.CLAIMS.FINANCIAL_TRANSACTIONS
WITH raw AS (
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        [{'role':'user','content':'Generate 200 realistic insurance financial transactions as a JSON array.
         Use line_nos LN-000001 through LN-000150.
         Each object:
         {"fxid":"FX-00001","line_no":"LN-000003","financial_type":"RSV",
          "currency":"USD","fin_tx_amt":5200.00,"fin_tx_post_dt":"2024-06-17"}.
         financial_type is either RSV (reserve) or PAY (payment).
         Reserves are set first, then payments follow. Amounts range from 500 to 75000.
         Return ONLY the pure JSON array. No explanation, no markdown, no code fences.'}],
        {'max_tokens': 4096, 'temperature': 0.7}
    ) AS raw_response
),
extracted AS (
    SELECT raw_response:choices[0]:messages::VARCHAR AS raw_json FROM raw
),
cleaned AS (
    SELECT TRIM(REPLACE(REPLACE(raw_json, '```json', ''), '```', '')) AS clean_json FROM extracted
)
SELECT 
    f.value:fxid::VARCHAR,
    f.value:line_no::VARCHAR,
    f.value:financial_type::VARCHAR,
    f.value:currency::VARCHAR,
    f.value:fin_tx_amt::NUMBER(12,2),
    f.value:fin_tx_post_dt::DATE
FROM cleaned, LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(clean_json)) f;

-- Generate synthetic call transcripts
INSERT INTO SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS
WITH raw AS (
    SELECT SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        [{'role':'user','content':'Generate 30 realistic insurance call transcripts as a JSON array.
         Use claim_nos CLM-00001 through CLM-00050 and customer_ids CUST-001 through CUST-050.
         Each object:
         {"transcript_id":"TR-001","claim_no":"CLM-00012","customer_id":"CUST-007",
          "call_date":"2024-06-17T14:30:00","caller_type":"CLAIMANT",
          "transcript_text":"Agent: Thank you for calling Sentinel Insurance. How can I help? Customer: I need to report damage to my car from last night...",
          "sentiment":"NEGATIVE","intent":"CLAIM_STATUS",
          "duration_seconds":420,"agent_id":"AGT-05"}.
         caller_type: CLAIMANT, POLICYHOLDER, THIRD_PARTY, VENDOR.
         sentiment: POSITIVE, NEGATIVE, NEUTRAL, FRUSTRATED.
         intent: CLAIM_STATUS, FILE_CLAIM, DISPUTE, PAYMENT_INQUIRY, DOCUMENT_REQUEST.
         Make transcripts 3-6 exchanges long and realistic.
         Return ONLY the pure JSON array. No explanation, no markdown, no code fences.'}],
        {'max_tokens': 4096, 'temperature': 0.7}
    ) AS raw_response
),
extracted AS (
    SELECT raw_response:choices[0]:messages::VARCHAR AS raw_json FROM raw
),
cleaned AS (
    SELECT TRIM(REPLACE(REPLACE(raw_json, '```json', ''), '```', '')) AS clean_json FROM extracted
)
SELECT 
    f.value:transcript_id::VARCHAR,
    f.value:claim_no::VARCHAR,
    f.value:customer_id::VARCHAR,
    f.value:call_date::TIMESTAMP,
    f.value:caller_type::VARCHAR,
    f.value:transcript_text::VARCHAR,
    f.value:sentiment::VARCHAR,
    f.value:intent::VARCHAR,
    f.value:duration_seconds::NUMBER,
    f.value:agent_id::VARCHAR
FROM cleaned, LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(clean_json)) f;


-- Generate policy document text and store as files
CREATE OR REPLACE PROCEDURE SENTINEL_DB.KNOWLEDGE.GENERATE_POLICY_DOCS()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'generate'
AS
$$
def generate(session):
    policies = session.sql("SELECT policy_id, policy_type FROM SENTINEL_DB.CLAIMS.POLICIES LIMIT 10").collect()
    for p in policies:
        doc_text = session.sql(f"""
            SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b',
                'Generate a realistic {p.POLICY_TYPE} insurance policy document for policy {p.POLICY_ID}. 
                 Include: declarations page, coverage sections, exclusions, conditions, endorsements.
                 Use realistic insurance language. 2-3 pages of content.')
        """).collect()[0][0]
        session.sql(f"""
            INSERT INTO SENTINEL_DB.KNOWLEDGE.PARSED_GUIDELINES 
            VALUES ('{p.POLICY_ID}_policy.txt', '{doc_text.replace("'","''")}', CURRENT_TIMESTAMP())
        """).collect()
    return 'Generated policy documents'
$$;

-- Table for parsed claim notes and guidelines
CREATE OR REPLACE TABLE SENTINEL_DB.KNOWLEDGE.PARSED_GUIDELINES (
    filename VARCHAR, extracted_content VARCHAR, parse_date TIMESTAMP
);

CREATE OR REPLACE TABLE SENTINEL_DB.KNOWLEDGE.PARSED_CLAIM_NOTES (
    filename VARCHAR, claim_no VARCHAR, 
    extracted_content VARCHAR, parse_date TIMESTAMP
);

call SENTINEL_DB.KNOWLEDGE.GENERATE_POLICY_DOCS();

-- If you have actual PDFs uploaded to stage, parse them: -- create pdf for it 
INSERT INTO SENTINEL_DB.KNOWLEDGE.PARSED_GUIDELINES
SELECT 
    relative_path AS filename,
    AI_PARSE_DOCUMENT(
        TO_FILE('@SENTINEL_DB.KNOWLEDGE.DOCS_STAGE', relative_path),
        {'mode': 'LAYOUT'}
    ):content::VARCHAR AS extracted_content,
    CURRENT_TIMESTAMP() AS parse_date
FROM DIRECTORY(@SENTINEL_DB.KNOWLEDGE.DOCS_STAGE);

select * from SENTINEL_DB.KNOWLEDGE.PARSED_GUIDELINES;

-- Chunk the guidelines for search indexing
CREATE OR REPLACE TABLE SENTINEL_DB.KNOWLEDGE.GUIDELINES_CHUNKS AS
SELECT
    filename,
    c.value::VARCHAR AS chunk_text
FROM SENTINEL_DB.KNOWLEDGE.PARSED_GUIDELINES,
    LATERAL FLATTEN(
        SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
            extracted_content, 'markdown', 1500, 200
        )
    ) c;

select * from SENTINEL_DB.KNOWLEDGE.GUIDELINES_CHUNKS;

select * from SENTINEL_DB.KNOWLEDGE.NOTES_CHUNKS;

 -- ============================================================
-- PROCESS: Populate PARSED_CLAIM_NOTES with LLM-generated notes
-- ============================================================
-- Since there are no claim-note PDFs on DOCS_STAGE, we use
-- CORTEX.COMPLETE to synthesize realistic adjuster notes for
-- each claim, drawing on the claim's own metadata (type, cause,
-- description, dates) so the notes are contextually accurate.
-- ============================================================

CREATE OR REPLACE PROCEDURE SENTINEL_DB.KNOWLEDGE.GENERATE_CLAIM_NOTES()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'generate'
AS
$$
def generate(session):
    claims = session.sql("""
        SELECT claim_no, claim_type, line_of_business, cause_of_loss,
               loss_description, loss_date, loss_state, claim_status
        FROM SENTINEL_DB.CLAIMS.CLAIMS
        ORDER BY claim_no
    """).collect()

    batch_size = 10
    inserted = 0
    for i in range(0, len(claims), batch_size):
        batch = claims[i:i+batch_size]
        values = []
        for c in batch:
            prompt = (
                f"Generate realistic insurance adjuster claim notes for claim {c.CLAIM_NO}. "
                f"Line of business: {c.LINE_OF_BUSINESS}. Cause of loss: {c.CAUSE_OF_LOSS}. "
                f"Loss description: {c.LOSS_DESCRIPTION}. Loss date: {c.LOSS_DATE}. "
                f"State: {c.LOSS_STATE}. Status: {c.CLAIM_STATUS}. "
                "Include 3-5 dated entries (YYYY-MM-DD format) from different adjusters covering: "
                "initial assessment, investigation findings, damage evaluation, repair estimates, "
                "and settlement recommendation. Use realistic insurance terminology. "
                "Return plain text only, no markdown code fences."
            )
            safe_prompt = prompt.replace("'", "''")
            note_result = session.sql(f"""
                SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', '{safe_prompt}')
            """).collect()
            note_text = note_result[0][0].replace("'", "''") if note_result else ''
            filename = f"{c.CLAIM_NO}_notes.txt"
            values.append(f"('{filename}', '{c.CLAIM_NO}', '{note_text}', CURRENT_TIMESTAMP())")
            inserted += 1

        if values:
            insert_sql = f"""
                INSERT INTO SENTINEL_DB.KNOWLEDGE.PARSED_CLAIM_NOTES
                (filename, claim_no, extracted_content, parse_date)
                VALUES {', '.join(values)}
            """
            session.sql(insert_sql).collect()

    return f'Generated claim notes for {inserted} claims'
$$;

CALL SENTINEL_DB.KNOWLEDGE.GENERATE_CLAIM_NOTES(); 
  
  
-- Chunk claim notes similarly
CREATE OR REPLACE TABLE SENTINEL_DB.KNOWLEDGE.NOTES_CHUNKS AS
SELECT
    filename, claim_no,
    c.value::VARCHAR AS chunk_text
FROM SENTINEL_DB.KNOWLEDGE.PARSED_CLAIM_NOTES,
    LATERAL FLATTEN(
        SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
            extracted_content, 'markdown', 1500, 200
        )
    ) c;

    ------------------------------

  --  **Step 2: Create Cortex Search services** — these become agent tools;
    --
    CREATE OR REPLACE CORTEX SEARCH SERVICE SENTINEL_DB.KNOWLEDGE.GUIDELINES_SEARCH
    ON chunk_text
    ATTRIBUTES filename
    WAREHOUSE = SENTINEL_WH
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS (
    SELECT chunk_text, filename
    FROM SENTINEL_DB.KNOWLEDGE.GUIDELINES_CHUNKS
);

-- Search service for claim-specific notes
CREATE OR REPLACE CORTEX SEARCH SERVICE SENTINEL_DB.KNOWLEDGE.CLAIM_NOTES_SEARCH
    ON chunk_text
    ATTRIBUTES filename, claim_no
    WAREHOUSE = SENTINEL_WH
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS (
    SELECT chunk_text, filename, claim_no
    FROM SENTINEL_DB.KNOWLEDGE.NOTES_CHUNKS
);


--**Step 3: AI processing pipeline for call transcripts** — this is the "Compliance Officer" persona


-- Process call transcripts with AI functions (if audio files exist)
-- For hackathon: generate text transcripts directly with COMPLETE
INSERT INTO from SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS
SELECT
    'TXCR-' || SEQ4() AS transcript_id,
    c.claim_no,
    c.customer_id,
    DATEADD('hour', UNIFORM(1, 72, RANDOM()), c.reported_date) AS call_date,
    'CUSTOMER' AS caller_type,
    SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b',
        CONCAT('Generate a realistic 3-minute insurance call transcript between a customer 
         and a call center agent about claim ', c.claim_no, 
         ' for ', c.cause_of_loss, '. Include speaker labels (AGENT: and CUSTOMER:). 
         The customer should express ', 
         CASE WHEN UNIFORM(0,1,RANDOM()) = 0 THEN 'frustration' ELSE 'concern' END,
         '. Include specific details about the incident.')
    ) AS transcript_text,
    NULL AS sentiment, NULL AS intent,
    UNIFORM(120, 600, RANDOM()) AS duration_seconds,
    'AGT-' || UNIFORM(1, 20, RANDOM()) AS agent_id
 FROM SENTINEL_DB.CLAIMS.CLAIMS c
LIMIT 50;

-- Enrich transcripts with AI_SENTIMENT and AI_EXTRACT
UPDATE SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS
SET 
    sentiment = AI_SENTIMENT(
        transcript_text, 
        ['Claims Process', 'Agent Professionalism', 'Resolution Satisfaction']
    )::VARCHAR,
    intent = AI_CLASSIFY(
        transcript_text,
        ['FNOL Report', 'Status Inquiry', 'Payment Question', 
         'Complaint', 'Document Submission', 'Policy Question']
    ):labels::VARCHAR;


--**Step 4: Row Access Policies** for governance demonstration


-- Claims access by agent tier
-- Step A: Detach the existing policy first
ALTER TABLE SENTINEL_DB.CLAIMS.CLAIMS
    DROP ROW ACCESS POLICY SENTINEL_DB.SECURITY.RAP_CLAIMS_TIER;

-- Step B: Recreate the policy
CREATE OR REPLACE ROW ACCESS POLICY SENTINEL_DB.SECURITY.RAP_CLAIMS_TIER
    AS (claim_region VARCHAR)
    RETURNS BOOLEAN ->
        IS_ROLE_IN_SESSION('ACCOUNTADMIN')
        OR IS_ROLE_IN_SESSION('SENTINEL_ADMIN')
        OR IS_ROLE_IN_SESSION('SENIOR_ADJUSTER')
        OR IS_ROLE_IN_SESSION('JUNIOR_ADJUSTER')
        OR (IS_ROLE_IN_SESSION('CALL_CENTER_AGENT') AND claim_region IN ('CA','TX','FL','NY','OR','WA'));

-- Step C: Re-attach the policy
ALTER TABLE SENTINEL_DB.CLAIMS.CLAIMS
    ADD ROW ACCESS POLICY SENTINEL_DB.SECURITY.RAP_CLAIMS_TIER
    ON (loss_state);


---
