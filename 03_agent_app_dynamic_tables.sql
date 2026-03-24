-- ## Phase 2: the action layer with Cortex Analyst and the Agent (hours 10–20)

-- This phase creates the semantic model for structured data queries (the "Underwriter" persona), builds the unified Cortex Agent, and connects everything through Streamlit.

-- **Step 1: Semantic model YAML** — upload to stage for Cortex Analyst

-- ```yaml
# File: sentinel_claims_model.yaml
# Upload: PUT file://sentinel_claims_model.yaml @SENTINEL_DB.MODELS.SEMANTIC_STAGE;

 name: sentinel_claims_analysis
description: |
  Insurance claims analysis model for Cortex Sentinel. Covers claims lifecycle, financial transactions, policy data, and customer information.
tables:
  - name: claims
    description: Insurance claims filed by policyholders, including FNOL and status tracking
    base_table:
      database: SENTINEL_DB
      schema: CLAIMS
      table: CLAIMS
    dimensions:
      - name: cause_of_loss
        synonyms:
          - loss cause
          - peril
          - reason
        description: What caused the insured loss
        expr: CAUSE_OF_LOSS
        data_type: VARCHAR
        sample_values:
          - COLLISION
          - FIRE
          - WATER_DAMAGE
          - THEFT
          - WIND
          - SLIP_AND_FALL
      - name: claim_no
        description: Unique claim identifier
        expr: CLAIM_NO
        data_type: VARCHAR
        unique: true
      - name: claim_status
        synonyms:
          - claim state
          - current status
          - status
        description: Current processing status of the claim
        expr: CLAIM_STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values:
          - OPEN
          - CLOSED
          - PENDING_REVIEW
          - DENIED
          - UNDER_INVESTIGATION
      - name: line_of_business
        synonyms:
          - business line
          - insurance type
          - LOB
          - product line
        description: Insurance line of business
        expr: LINE_OF_BUSINESS
        data_type: VARCHAR
        is_enum: true
        sample_values:
          - AUTO
          - HOME
          - COMMERCIAL
          - WORKERS_COMP
          - GL
      - name: loss_state
        synonyms:
          - claim location
          - jurisdiction
          - state
        description: US state where loss occurred
        expr: LOSS_STATE
        data_type: VARCHAR
      - name: performer
        synonyms:
          - adjuster
          - assigned to
          - handler
        description: Claims adjuster handling this claim
        expr: PERFORMER
        data_type: VARCHAR
      - name: policy_id
        description: Foreign key to policies table
        expr: POLICY_ID
        data_type: VARCHAR
    time_dimensions:
      - name: loss_date
        synonyms:
          - accident date
          - date of loss
          - incident date
        description: Date the insured event occurred
        expr: LOSS_DATE
        data_type: DATE
      - name: reported_date
        synonyms:
          - date reported
          - FNOL date
          - notification date
        description: Date claim was first reported
        expr: REPORTED_DATE
        data_type: DATE
    filters:
      - name: closed_claims
        description: Claims that are closed or denied
        expr: CLAIM_STATUS IN ('CLOSED', 'DENIED')
      - name: open_claims
        description: Claims currently open or under review
        expr: CLAIM_STATUS IN ('OPEN', 'PENDING_REVIEW', 'UNDER_INVESTIGATION')
    metrics:
      - name: average_days_to_report
        synonyms:
          - days to FNOL
          - reporting lag
        description: Average days between loss and first report
        expr: AVG(DATEDIFF('day', LOSS_DATE, REPORTED_DATE))
      - name: claim_count
        synonyms:
          - claims filed
          - number of claims
          - total claims
        description: Total number of distinct claims
        expr: COUNT(DISTINCT CLAIM_NO)
    primary_key:
      columns:
        - CLAIM_NO
  - name: claim_lines
    description: Itemized line items within each claim, linking claims to financial transactions
    base_table:
      database: SENTINEL_DB
      schema: CLAIMS
      table: CLAIM_LINES
    dimensions:
      - name: claim_no
        description: Parent claim number
        expr: CLAIM_NO
        data_type: VARCHAR
      - name: line_no
        description: Unique claim line identifier
        expr: LINE_NO
        data_type: VARCHAR
        unique: true
      - name: line_status
        synonyms:
          - line claim status
        description: Status of this claim line
        expr: CLAIM_STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values:
          - OPEN
          - CLOSED
          - PENDING_REVIEW
          - DENIED
      - name: performer_id
        synonyms:
          - line adjuster
        description: Adjuster handling this line
        expr: PERFORMER_ID
        data_type: VARCHAR
    time_dimensions:
      - name: line_created_date
        description: Date the claim line was created
        expr: CREATED_DATE
        data_type: TIMESTAMP
    primary_key:
      columns:
        - LINE_NO
  - name: financial_transactions
    description: Payment and reserve transactions on claim lines
    base_table:
      database: SENTINEL_DB
      schema: CLAIMS
      table: FINANCIAL_TRANSACTIONS
    dimensions:
      - name: financial_type
        synonyms:
          - transaction type
          - type
        description: RSV = reserve set, PAY = payment made
        expr: FINANCIAL_TYPE
        data_type: VARCHAR
        is_enum: true
        sample_values:
          - RSV
          - PAY
      - name: line_no
        description: Foreign key to claim lines
        expr: LINE_NO
        data_type: VARCHAR
    time_dimensions:
      - name: transaction_date
        synonyms:
          - payment date
          - posting date
        description: Date transaction was posted
        expr: FIN_TX_POST_DT
        data_type: DATE
    facts:
      - name: transaction_amount
        description: Dollar amount of the transaction
        expr: FIN_TX_AMT
        data_type: NUMBER
    metrics:
      - name: total_incurred
        synonyms:
          - incurred
          - total incurred losses
        description: Total incurred = payments + reserves
        expr: SUM(FIN_TX_AMT)
      - name: total_paid
        synonyms:
          - paid amount
          - total payments
          - total payouts
        description: Sum of all payment transactions
        expr: SUM(CASE WHEN FINANCIAL_TYPE = 'PAY' THEN FIN_TX_AMT ELSE 0 END)
      - name: total_reserves
        synonyms:
          - outstanding reserves
          - reserve amount
        description: Sum of all reserve transactions
        expr: SUM(CASE WHEN FINANCIAL_TYPE = 'RSV' THEN FIN_TX_AMT ELSE 0 END)
  - name: policies
    description: Insurance policies with coverage and premium details
    base_table:
      database: SENTINEL_DB
      schema: CLAIMS
      table: POLICIES
    dimensions:
      - name: policy_id
        synonyms:
          - policy number
        description: Unique policy identifier
        expr: POLICY_ID
        data_type: VARCHAR
        unique: true
      - name: policy_type
        synonyms:
          - coverage type
          - product
        description: Type of insurance policy
        expr: POLICY_TYPE
        data_type: VARCHAR
        is_enum: true
        sample_values:
          - AUTO
          - HOME
          - COMMERCIAL
          - WORKERS_COMP
          - GL
      - name: status
        synonyms:
          - policy status
        description: Active, expired, cancelled
        expr: STATUS
        data_type: VARCHAR
        is_enum: true
        sample_values:
          - ACTIVE
          - EXPIRED
          - CANCELLED
          - PENDING
    facts:
      - name: annual_premium
        synonyms:
          - premium
          - written premium
        description: Annual premium amount
        expr: ANNUAL_PREMIUM
        data_type: NUMBER
    metrics:
      - name: policy_count
        synonyms:
          - number of policies
          - policies in force
        description: Count of distinct policies
        expr: COUNT(DISTINCT POLICY_ID)
      - name: total_premium
        synonyms:
          - premium volume
          - total written premium
        description: Sum of all annual premiums
        expr: SUM(ANNUAL_PREMIUM)
    primary_key:
      columns:
        - POLICY_ID
metrics:
  - name: loss_ratio
    description: Loss ratio = total incurred / total premium. Key profitability metric.
    synonyms:
      - claims ratio
      - loss ratio percentage
    expr: financial_transactions.total_incurred / NULLIF(policies.total_premium, 0)
relationships:
  - name: claims_to_policies
    left_table: claims
    right_table: policies
    relationship_columns:
      - left_column: POLICY_ID
        right_column: POLICY_ID
  - name: claim_lines_to_claims
    left_table: claim_lines
    right_table: claims
    relationship_columns:
      - left_column: CLAIM_NO
        right_column: CLAIM_NO
  - name: financial_to_claim_lines
    left_table: financial_transactions
    right_table: claim_lines
    relationship_columns:
      - left_column: LINE_NO
        right_column: LINE_NO
verified_queries:
  - name: monthly_claims_count
    question: How many claims were filed each month this year?
    use_as_onboarding_question: true
    verified_by: Hackathon Team
    verified_at: 1710000000
    sql: |
      SELECT DATE_TRUNC('MONTH', loss_date) AS month,
             COUNT(DISTINCT claim_no) AS claim_count
      FROM __claims
      WHERE YEAR(loss_date) = YEAR(CURRENT_DATE())
      GROUP BY month ORDER BY month
  - name: top_states_incurred
    question: What are the top 10 states by total incurred losses?
    use_as_onboarding_question: true
    verified_by: Hackathon Team
    verified_at: 1710000000
    sql: |
      SELECT loss_state,
             SUM(transaction_amount) AS total_incurred
      FROM __claims
      JOIN __claim_lines ON __claims.claim_no = __claim_lines.claim_no
      JOIN __financial_transactions ON __claim_lines.line_no = __financial_transactions.line_no
      GROUP BY loss_state
      ORDER BY total_incurred DESC LIMIT 10
  - name: loss_ratio_by_lob
    question: What is the loss ratio by line of business?
    use_as_onboarding_question: true
    verified_by: Hackathon Team
    verified_at: 1710000000
    sql: |
      SELECT line_of_business,
             SUM(transaction_amount) AS total_incurred,
             SUM(annual_premium) AS total_premium,
             SUM(transaction_amount) / NULLIF(SUM(annual_premium), 0) AS loss_ratio
      FROM __claims
      JOIN __policies ON __claims.policy_id = __policies.policy_id
      JOIN __claim_lines ON __claims.claim_no = __claim_lines.claim_no
      JOIN __financial_transactions ON __claim_lines.line_no = __financial_transactions.line_no
      GROUP BY line_of_business ORDER BY loss_ratio DESC
  - name: open_claims_by_lob
    question: How many open claims are there by line of business?
    use_as_onboarding_question: true
    verified_by: Hackathon Team
    verified_at: 1710000000
    sql: |
      SELECT line_of_business, COUNT(DISTINCT claim_no) AS open_count
      FROM __claims
      WHERE claim_status IN ('OPEN', 'PENDING_REVIEW', 'UNDER_INVESTIGATION')
      GROUP BY line_of_business ORDER BY open_count DESC


**Step 2: Upload semantic model and create custom tools**

```sql
-- Upload the YAML (from local machine or use CoCo to generate)
-- PUT file://sentinel_claims_model.yaml @SENTINEL_DB.MODELS.SEMANTIC_STAGE;

-- Custom tool: Document classification
CREATE OR REPLACE FUNCTION SENTINEL_DB.CLAIMS.CLASSIFY_DOCUMENT(doc_text VARCHAR)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
    AI_CLASSIFY(
        doc_text,
        [
            {'label': 'Insurance Claim Form', 'description': 'A first notice of loss or claim submission'},
            {'label': 'Medical Bill', 'description': 'Medical or healthcare billing document'},
            {'label': 'Invoice', 'description': 'Vendor or repair invoice'},
            {'label': 'Police Report', 'description': 'Law enforcement incident report'},
            {'label': 'Policy Document', 'description': 'Insurance policy or endorsement'},
            {'label': 'Correspondence', 'description': 'Letter or email communication'}
        ],
        {'task_description': 'Classify insurance claim-related documents by type'}
    )
$$;

-- Custom tool: Fraud risk scoring
CREATE OR REPLACE FUNCTION SENTINEL_DB.CLAIMS.ASSESS_FRAUD_RISK(claim_details VARCHAR)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
    SNOWFLAKE.CORTEX.COMPLETE(
        'claude-4-sonnet',
        [
            {'role': 'system', 'content': 'You are an insurance fraud analyst. Analyze claim details for red flags. Return JSON: {"risk_score": 1-10, "red_flags": ["flag1"], "recommendation": "approve|investigate|deny", "reasoning": "brief explanation"}'},
            {'role': 'user', 'content': claim_details}
        ],
        {'temperature': 0.1, 'max_tokens': 500}
    )
$$;


-- **Step 3: Create the unified Cortex Agent** — the centerpiece of Cortex Sentinel

-- ```sql
CREATE OR REPLACE AGENT SENTINEL_DB.APPS.CORTEX_SENTINEL_AGENT
    COMMENT = 'Cortex Sentinel - Agentic Financial Operating System for Insurance Claims'
    FROM SPECIFICATION
    $$
    models:
        orchestration: auto

    orchestration:
        budget:
            seconds: 45
            tokens: 20000

    instructions:
        system: |
            You are Cortex Sentinel, an AI-powered Financial Operating System for insurance 
            claims processing. You serve three roles:
            
            1. COMPLIANCE OFFICER: Audit claims for regulatory compliance, check authorization 
               limits, verify settlement timelines, detect anomalies.
            2. UNDERWRITER: Analyze claims data, calculate loss ratios, assess risk, 
               generate financial reports and metrics.
            3. LIBRARIAN: Search policy documents, guidelines, claim notes, and regulatory 
               requirements to find relevant information.
            
            Always be precise with financial figures. Round currency to 2 decimal places.
            When showing claims data, include claim_no for reference.
            Cite document sources when using search results.
            
        orchestration: |
            - For questions about claims metrics, financial summaries, loss ratios, premium 
              analysis, or any quantitative business question: use ClaimsAnalyst
            - For questions about policy terms, coverage details, regulatory guidelines, 
              or compliance procedures: use GuidelinesSearch
            - For questions about specific claim history, adjuster notes, or claim-specific 
              context: use ClaimNotesSearch
            - For document classification requests: use DocumentClassifier
            - For fraud risk assessment: use FraudAssessor
            - For data visualization: use data_to_chart after getting data from ClaimsAnalyst
            
        sample_questions:
            - question: "What is the loss ratio by line of business?"
              answer: "I'll query our claims and premium data to calculate loss ratios."
            - question: "What does our policy say about flood damage exclusions?"
              answer: "I'll search our policy guidelines for flood damage coverage details."
            - question: "Show me all open claims over $50,000"
              answer: "I'll query our claims database for high-value open claims."
            - question: "Is claim CLM-001 within the adjuster's authorization limit?"
              answer: "I'll check the authorization table and claim financials for compliance."

    tools:
        - tool_spec:
            type: cortex_analyst_text_to_sql
            name: ClaimsAnalyst
            description: >
                Converts natural language questions into SQL queries against insurance claims,
                policies, financial transactions, and customer data. Use for any quantitative
                analysis: claim counts, loss ratios, premium summaries, trend analysis,
                financial metrics, adjuster workload, and compliance metrics.
        - tool_spec:
            type: cortex_search
            name: GuidelinesSearch
            description: >
                Searches insurance policy documents, regulatory guidelines, compliance 
                procedures, and coverage terms. Use for policy interpretation, coverage 
                questions, regulatory requirements, and procedure lookups.
        - tool_spec:
            type: cortex_search
            name: ClaimNotesSearch
            description: >
                Searches claim-specific notes, adjuster reports, investigation findings, 
                and claim correspondence. Use for claim history, investigation details,
                and claim-specific context.
        - tool_spec:
            type: generic
            name: DocumentClassifier
            description: >
                Classifies insurance documents into categories: Insurance Claim Form,
                Medical Bill, Invoice, Police Report, Policy Document, or Correspondence.
        - tool_spec:
            type: generic
            name: FraudAssessor
            description: >
                Analyzes claim details for fraud indicators and returns a risk score (1-10),
                identified red flags, and a recommendation (approve/investigate/deny).
        - tool_spec:
            type: data_to_chart
            name: data_to_chart
            description: "Generates Vega-Lite chart visualizations from query results"

    tool_resources:
        ClaimsAnalyst:
            semantic_model_file: "@SENTINEL_DB.MODELS.SEMANTIC_STAGE/sentinel_claims_model.yaml"
            execution_environment:
                type: warehouse
                warehouse: SENTINEL_WH
                query_timeout: 60
        GuidelinesSearch:
            name: "SENTINEL_DB.KNOWLEDGE.GUIDELINES_SEARCH"
            max_results: "5"
            title_column: "filename"
        ClaimNotesSearch:
            name: "SENTINEL_DB.KNOWLEDGE.CLAIM_NOTES_SEARCH"
            max_results: "5"
            title_column: "filename"
        DocumentClassifier:
            identifier: "SENTINEL_DB.CLAIMS.CLASSIFY_DOCUMENT"
            execution_environment:
                type: warehouse
                warehouse: SENTINEL_WH
                query_timeout: 30
        FraudAssessor:
            identifier: "SENTINEL_DB.CLAIMS.ASSESS_FRAUD_RISK"
            execution_environment:
                type: warehouse
                warehouse: SENTINEL_WH
                query_timeout: 30
    $$;




-- ## Phase 2b: the Streamlit call center app (hours 16–22)

-- The front-end runs on **Container Runtime** (required for Cortex Agents API). This creates a professional call center dashboard with an AI chat interface.

-- ```python
-- # streamlit_app.py — Cortex Sentinel Call Center Dashboard

```

**Create the Streamlit app in Snowflake:**

--```sql
-- Create compute pool for container runtime
CREATE COMPUTE POOL IF NOT EXISTS SENTINEL_POOL
    MIN_NODES = 1 MAX_NODES = 2
    INSTANCE_FAMILY = CPU_X64_XS;

-- Create the Streamlit app
CREATE STREAMLIT SENTINEL_DB.APPS.CORTEX_SENTINEL_APP
    RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
    COMPUTE_POOL = SENTINEL_POOL
    QUERY_WAREHOUSE = SENTINEL_WH;
--```


---------------------------------------------
-- ## Phase 2c: real-time ingestion with Dynamic Tables (hours 18–22)

-- Dynamic Tables create the **live Customer 360 view** that updates automatically as new claims stream in. For hackathon simplicity, use a Task-based simulation instead of Snowpipe Streaming's Java SDK.

-- ```sql
-- Simulate streaming with a scheduled Task
CREATE OR REPLACE PROCEDURE SENTINEL_DB.CLAIMS.SIMULATE_NEW_CLAIMS(batch_size INT)
RETURNS STRING LANGUAGE SQL AS
$$
BEGIN
    INSERT INTO SENTINEL_DB.CLAIMS.CLAIMS
    SELECT 
        'CLM-' || UUID_STRING(),
        p.policy_id, p.customer_id,
        ARRAY_CONSTRUCT('COLLISION','FIRE','WATER_DAMAGE','THEFT','WIND')[UNIFORM(0,4,RANDOM())],
        'OPEN',
        p.policy_type,
        ARRAY_CONSTRUCT('COLLISION','FIRE','WATER','THEFT','WIND')[UNIFORM(0,4,RANDOM())],
        'Auto-generated loss description for simulation',
        DATEADD('day', -UNIFORM(0, 30, RANDOM()), CURRENT_DATE()),
        CURRENT_DATE(), NULL,
        ARRAY_CONSTRUCT('CA','TX','FL','NY','OR','WA')[UNIFORM(0,5,RANDOM())],
        LPAD(UNIFORM(10000,99999,RANDOM())::VARCHAR, 5, '0'),
        'ADJ-' || UNIFORM(1,15,RANDOM()),
        p.customer_id,
        CURRENT_TIMESTAMP()
    FROM SENTINEL_DB.CLAIMS.POLICIES p
    WHERE p.status = 'ACTIVE'
    ORDER BY RANDOM() LIMIT :batch_size;
    RETURN 'Inserted ' || :batch_size || ' simulated claims';
END;
$$;

CREATE TASK SENTINEL_DB.CLAIMS.STREAMING_SIMULATOR
    WAREHOUSE = SENTINEL_WH
    SCHEDULE = '2 MINUTE'
    AS CALL SENTINEL_DB.CLAIMS.SIMULATE_NEW_CLAIMS(5);

ALTER TASK SENTINEL_DB.CLAIMS.STREAMING_SIMULATOR RESUME;

-- Dynamic Table: Customer 360 (auto-refreshes every 5 minutes)
CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.CLAIMS.CUSTOMER_360
    TARGET_LAG = '5 minutes'
    WAREHOUSE = SENTINEL_WH
AS
    SELECT
        c.customer_id,
        c.first_name || ' ' || c.last_name AS full_name,
        c.email, c.phone, c.segment,
        COUNT(DISTINCT p.policy_id) AS active_policies,
        SUM(p.annual_premium) AS total_premium,
        COUNT(DISTINCT cl.claim_no) AS total_claims,
        SUM(CASE WHEN cl.claim_status IN ('OPEN','PENDING_REVIEW') THEN 1 ELSE 0 END) AS open_claims,
        MAX(cl.reported_date) AS last_claim_date,
        DATEDIFF('day', MAX(cl.reported_date), CURRENT_DATE()) AS days_since_last_claim
    FROM SENTINEL_DB.CLAIMS.CUSTOMERS c
    LEFT JOIN SENTINEL_DB.CLAIMS.POLICIES p 
        ON c.customer_id = p.customer_id AND p.status = 'ACTIVE'
    LEFT JOIN SENTINEL_DB.CLAIMS.CLAIMS cl 
        ON c.customer_id = cl.customer_id
    GROUP BY 1, 2, 3, 4, 5;

-- Dynamic Table: Claims Severity Heatmap (for dashboard)
CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.CLAIMS.CLAIMS_SEVERITY_MAP
    TARGET_LAG = '5 minutes'
    WAREHOUSE = SENTINEL_WH
AS
    SELECT
        cl.loss_state,
        cl.line_of_business,
        COUNT(DISTINCT cl.claim_no) AS claim_count,
        SUM(ft.fin_tx_amt) AS total_incurred,
        AVG(ft.fin_tx_amt) AS avg_severity,
        SUM(CASE WHEN cl.claim_status = 'OPEN' THEN 1 ELSE 0 END) AS open_count
    FROM SENTINEL_DB.CLAIMS.CLAIMS cl
    LEFT JOIN SENTINEL_DB.CLAIMS.FINANCIAL_TRANSACTIONS ft ON cl.claim_no = ft.line_no
    GROUP BY 1, 2;
-- ```

-- ---

-- ## Phase 3: the sovereign decision engine and feedback loop (hours 22–28)

-- Phase 3 adds the intelligence layer — automated decision routing, compliance checks, and a feedback mechanism that continuously improves the agent. This is what elevates the project from a demo to a sovereign operating system.

-- **Automated compliance checking** runs as a scheduled task that flags violations:

-- ```sql
-- Compliance monitor: check authorization limits
CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.CLAIMS.COMPLIANCE_ALERTS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = SENTINEL_WH
AS
    SELECT
        cl.claim_no,
        cl.performer,
        ft.fin_tx_amt AS payment_amount,
        a.to_amt AS authorization_limit,
        CASE WHEN ft.fin_tx_amt > a.to_amt THEN 'OVER_LIMIT' ELSE 'COMPLIANT' END AS status,
        ft.fin_tx_post_dt AS payment_date
    FROM SENTINEL_DB.CLAIMS.CLAIMS cl
    JOIN SENTINEL_DB.CLAIMS.CLAIM_LINES cll ON cl.claim_no = cll.claim_no
    JOIN SENTINEL_DB.CLAIMS.FINANCIAL_TRANSACTIONS ft ON cll.line_no = ft.line_no
    JOIN SENTINEL_DB.CLAIMS.AUTHORIZATION a ON cl.performer = a.performer_id
    WHERE ft.financial_type = 'PAY' AND ft.fin_tx_amt > a.to_amt;


-- **Feedback table** captures agent response quality for continuous improvement:

-- ```sql
CREATE TABLE SENTINEL_DB.APPS.AGENT_FEEDBACK (
    feedback_id     VARCHAR DEFAULT UUID_STRING(),
    request_id      VARCHAR,
    question        VARCHAR,
    response_text   VARCHAR,
    is_positive     BOOLEAN,
    feedback_notes  VARCHAR,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Analytics on agent performance
CREATE OR REPLACE DYNAMIC TABLE SENTINEL_DB.APPS.AGENT_PERFORMANCE
    TARGET_LAG = '30 minutes'
    WAREHOUSE = SENTINEL_WH
AS
    SELECT
        DATE_TRUNC('day', created_at) AS day,
        COUNT(*) AS total_interactions,
        SUM(CASE WHEN is_positive THEN 1 ELSE 0 END) AS positive_count,
        ROUND(positive_count / NULLIF(total_interactions, 0) * 100, 1) AS satisfaction_pct
    FROM SENTINEL_DB.APPS.AGENT_FEEDBACK
    GROUP BY 1;
```
