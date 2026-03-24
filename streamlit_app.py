import json
import re
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="Cortex Sentinel", page_icon="🛡️", layout="wide")

DB = "SENTINEL_DB"
SCHEMA = "APPS"
LLM_MODEL = "claude-3-5-sonnet"

SCHEMA_CONTEXT = """You have access to these Snowflake tables:

1. SENTINEL_DB.CLAIMS.CLAIMS (claim_no PK, policy_id, customer_id, claim_type, claim_status [OPEN/CLOSED/PENDING_REVIEW/DENIED/UNDER_INVESTIGATION], line_of_business [AUTO/HOME/COMMERCIAL/GL/WORKERS_COMP], cause_of_loss, loss_description, loss_date DATE, reported_date DATE "when the claim was filed/reported", fnol_completion_date, loss_state, loss_zip_code, performer, claimant_id, created_date TIMESTAMP "system record creation timestamp, NOT when claim was filed")
2. SENTINEL_DB.CLAIMS.CLAIM_LINES (claim_no, line_no)
3. SENTINEL_DB.CLAIMS.FINANCIAL_TRANSACTIONS (line_no, fin_tx_amt NUMERIC, fin_tx_post_dt DATE, financial_type VARCHAR [PAY/RSV] where PAY=payment and RSV=reserve)
4. SENTINEL_DB.CLAIMS.POLICIES (policy_id PK, customer_id, policy_type [AUTO/HOME/COMMERCIAL/GL/WORKERS_COMP], effective_date, expiration_date, annual_premium NUMERIC, coverage_limit, deductible, status [ACTIVE/INACTIVE/etc])
5. SENTINEL_DB.CLAIMS.CUSTOMERS (customer_id PK, first_name, last_name, email, phone, segment)
6. SENTINEL_DB.CLAIMS.CUSTOMER_360 (dynamic table: customer_id, full_name, email, phone, segment, active_policies, total_premium, total_claims, open_claims, last_claim_date, days_since_last_claim)
7. SENTINEL_DB.CLAIMS.CLAIMS_SEVERITY_MAP (dynamic table: loss_state, line_of_business, claim_count, total_incurred, avg_severity, open_count)
8. SENTINEL_DB.CLAIMS.CALL_TRANSCRIPTS (transcript_id PK, claim_no, customer_id, call_date, caller_type, transcript_text, sentiment, intent, duration_seconds, agent_id)

Key joins:
- CLAIMS.claim_no -> CLAIM_LINES.claim_no
- CLAIM_LINES.line_no -> FINANCIAL_TRANSACTIONS.line_no
- CLAIMS.policy_id -> POLICIES.policy_id
- CLAIMS.customer_id -> CUSTOMERS.customer_id
- POLICIES.policy_type matches CLAIMS.line_of_business values
"""

SYSTEM_PROMPT = f"""You are Cortex Sentinel, an AI-powered Financial Operating System for insurance claims.
You serve as: Compliance Officer, Underwriter, and Librarian.

{SCHEMA_CONTEXT}

RULES:
- For data/analytics questions: generate a single Snowflake SQL query. Return ONLY valid JSON: {{"type": "sql", "sql": "<query>", "explanation": "<brief>"}}
- For policy/guideline questions: return JSON: {{"type": "search", "query": "<search terms>"}}
- For fraud assessment requests (keywords: fraud, suspicious, red flags, investigate claim, risk assessment): return JSON: {{"type": "fraud", "claim_no": "<CLM-XXXXX if mentioned, else null>", "concern": "<user's fraud concern>"}}
- For document classification requests (keywords: classify, what type of document, categorize document): return JSON: {{"type": "classify", "document_text": "<the document text to classify>"}}
- For general questions or analysis of provided data: return JSON: {{"type": "text", "text": "<your answer>"}}
- Always use fully qualified table names (DATABASE.SCHEMA.TABLE).
- Use reported_date (not created_date) when asked about when claims were filed.
- financial_type values are PAY (payments) and RSV (reserves), never RESERVE.
- Return ONLY the JSON object, no markdown fences, no extra text."""

col1, col2 = st.columns([3, 1])
with col1:
    st.title("🛡️ Cortex Sentinel")
    st.caption("Agentic Financial Operating System — Insurance Claims")
with col2:
    role = st.selectbox("Agent Role", ["All Roles", "Compliance Officer",
                                        "Underwriter", "Librarian"])

with st.sidebar:
    st.header("📊 Claims Dashboard")
    stats = session.sql("""
        SELECT
            COUNT(DISTINCT claim_no) AS total_claims,
            SUM(CASE WHEN claim_status IN ('OPEN','PENDING_REVIEW') THEN 1 ELSE 0 END) AS open_claims,
            COUNT(DISTINCT CASE WHEN reported_date >= DATEADD('day', -7, CURRENT_DATE())
                  THEN claim_no END) AS new_this_week
        FROM SENTINEL_DB.CLAIMS.CLAIMS
    """).to_pandas()

    st.metric("Total Claims", f"{stats['TOTAL_CLAIMS'][0]:,}")
    st.metric("Open Claims", f"{stats['OPEN_CLAIMS'][0]:,}")
    st.metric("New This Week", f"{stats['NEW_THIS_WEEK'][0]:,}")

    st.divider()
    st.header("💡 Try asking:")
    suggestions = [
        "What is the loss ratio by line of business?",
        "Show me all open claims over $50,000",
        "What does our policy say about flood exclusions?",
        "Assess fraud risk for claim CLM-00023",
        "Classify this document: Invoice from Joe's Auto Body for bumper repair $2500",
        "How many claims were filed each month this year?"
    ]
    for s in suggestions:
        if st.button(s, key=s):
            st.session_state.pending_question = s

if "messages" not in st.session_state:
    st.session_state.messages = []

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        if msg.get("type") == "sql_result":
            st.code(msg.get("sql", ""), language="sql")
            if msg.get("data") is not None:
                st.dataframe(msg["data"])
            if msg.get("analysis"):
                st.markdown(msg["analysis"])
        else:
            st.markdown(msg["content"])


def llm_complete(prompt):
    escaped = prompt.replace("$$", "$ $")
    result = session.sql(f"""
        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            '{LLM_MODEL}',
            $${escaped}$$
        ) AS response
    """).to_pandas()
    return result['RESPONSE'][0]


def llm_route(prompt):
    escaped = prompt.replace("$$", "$ $")
    result = session.sql(f"""
        WITH llm AS (
            SELECT SNOWFLAKE.CORTEX.COMPLETE('{LLM_MODEL}', $${escaped}$$) AS raw_resp
        ),
        cleaned AS (
            SELECT raw_resp,
                COALESCE(
                    TRY_PARSE_JSON(REPLACE(REPLACE(TRIM(raw_resp), '\\n', ' '), '\\r', ' ')),
                    TRY_PARSE_JSON(REPLACE(REPLACE(
                        REGEXP_SUBSTR(TRIM(raw_resp), '\\\\{{.*\\\\}}', 1, 1, 's'),
                        '\\n', ' '), '\\r', ' '))
                ) AS parsed
            FROM llm
        )
        SELECT
            raw_resp,
            parsed:type::VARCHAR AS resp_type,
            parsed:sql::VARCHAR AS resp_sql,
            parsed:explanation::VARCHAR AS resp_explanation,
            parsed:query::VARCHAR AS resp_query,
            parsed:text::VARCHAR AS resp_text,
            parsed:claim_no::VARCHAR AS resp_claim_no,
            parsed:concern::VARCHAR AS resp_concern,
            parsed:document_text::VARCHAR AS resp_doc_text
        FROM cleaned
    """).to_pandas()
    row = result.iloc[0]
    if row['RESP_TYPE']:
        return {
            'type': row['RESP_TYPE'],
            'sql': row['RESP_SQL'],
            'explanation': row['RESP_EXPLANATION'],
            'query': row['RESP_QUERY'],
            'text': row['RESP_TEXT'],
            'claim_no': row.get('RESP_CLAIM_NO'),
            'concern': row.get('RESP_CONCERN'),
            'document_text': row.get('RESP_DOC_TEXT'),
        }
    return {'type': 'raw', 'text': row['RAW_RESP']}


def cortex_search(query, service="GUIDELINES_SEARCH"):
    escaped_query = query.replace('"', '\\"').replace("'", "\\'")
    result = session.sql(f"""
        SELECT PARSE_JSON(
            SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'SENTINEL_DB.KNOWLEDGE.{service}',
                '{{"query": "{escaped_query}", "columns": ["CHUNK_TEXT", "FILENAME"], "limit": 3}}'
            )
        )['results'] AS results
    """).to_pandas()
    return json.loads(result['RESULTS'][0]) if result['RESULTS'][0] else []


def extract_claim_no(text):
    match = re.search(r'CLM-\d+', text, re.IGNORECASE)
    return match.group(0).upper() if match else None


def get_claim_data(claim_no):
    escaped = claim_no.replace("'", "''")
    try:
        df = session.sql(f"""
            SELECT
                c.claim_no, c.policy_id, c.customer_id, c.claim_type, c.claim_status,
                c.line_of_business, c.cause_of_loss, c.loss_description,
                c.loss_date, c.reported_date, c.loss_state, c.performer,
                p.policy_type, p.effective_date, p.expiration_date,
                p.annual_premium, p.coverage_limit, p.deductible, p.status AS policy_status,
                cust.first_name, cust.last_name, cust.segment,
                SUM(CASE WHEN ft.financial_type = 'PAY' THEN ft.fin_tx_amt ELSE 0 END) AS total_paid,
                SUM(CASE WHEN ft.financial_type = 'RSV' THEN ft.fin_tx_amt ELSE 0 END) AS total_reserved,
                SUM(ft.fin_tx_amt) AS total_incurred,
                COUNT(DISTINCT ft.line_no) AS transaction_count
            FROM SENTINEL_DB.CLAIMS.CLAIMS c
            LEFT JOIN SENTINEL_DB.CLAIMS.POLICIES p ON c.policy_id = p.policy_id
            LEFT JOIN SENTINEL_DB.CLAIMS.CUSTOMERS cust ON c.customer_id = cust.customer_id
            LEFT JOIN SENTINEL_DB.CLAIMS.CLAIM_LINES cl ON c.claim_no = cl.claim_no
            LEFT JOIN SENTINEL_DB.CLAIMS.FINANCIAL_TRANSACTIONS ft ON cl.line_no = ft.line_no
            WHERE c.claim_no = '{escaped}'
            GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
        """).to_pandas()
        if len(df) > 0:
            return df
    except Exception:
        pass
    return None


def get_customer_claim_history(customer_id):
    escaped = customer_id.replace("'", "''")
    try:
        df = session.sql(f"""
            SELECT claim_no, claim_status, cause_of_loss, line_of_business,
                   loss_date, reported_date
            FROM SENTINEL_DB.CLAIMS.CLAIMS
            WHERE customer_id = '{escaped}'
            ORDER BY reported_date DESC
            LIMIT 10
        """).to_pandas()
        return df
    except Exception:
        return None


def assess_fraud(claim_no, user_concern, user_prompt):
    claim_data = get_claim_data(claim_no) if claim_no else None

    if claim_data is not None and len(claim_data) > 0:
        row = claim_data.iloc[0]
        customer_id = row.get('CUSTOMER_ID', '')
        history = get_customer_claim_history(customer_id) if customer_id else None

        st.markdown("**Claim Data Retrieved from Database:**")
        st.dataframe(claim_data, use_container_width=True)

        claim_summary = claim_data.to_string(index=False)
        history_summary = history.to_string(index=False) if history is not None and len(history) > 0 else "No prior claims found."

        combined = (
            f"ACTUAL CLAIM DATA FROM DATABASE:\n{claim_summary}\n\n"
            f"CUSTOMER CLAIM HISTORY:\n{history_summary}\n\n"
            f"USER CONCERN:\n{user_concern or user_prompt}"
        )
    else:
        if claim_no:
            st.warning(f"Claim {claim_no} not found in database. Assessing based on provided details only.")
        combined = f"USER-PROVIDED SCENARIO (no matching claim in database):\n{user_prompt}"

    escaped = combined.replace("'", "''").replace("$$", "$ $")
    try:
        result = session.sql(f"""
            SELECT SENTINEL_DB.CLAIMS.ASSESS_FRAUD_RISK($${escaped}$$) AS risk
        """).to_pandas()
        risk_raw = result['RISK'][0]

        if isinstance(risk_raw, str):
            risk_json = json.loads(risk_raw)
        else:
            risk_json = risk_raw

        score = risk_json.get('risk_score', 0)
        try:
            score = int(score)
        except (ValueError, TypeError):
            score = 0
        flags = risk_json.get('red_flags', [])
        recommendation = risk_json.get('recommendation', 'N/A')
        reasoning = risk_json.get('reasoning', '')

        score_color = "🟢" if score <= 3 else "🟡" if score <= 6 else "🔴"

        response_text = f"""### {score_color} Fraud Risk Assessment

**Risk Score:** {score}/10
**Recommendation:** {recommendation.upper()}

**Red Flags Identified:**
"""
        for flag in flags:
            response_text += f"- {flag}\n"

        response_text += f"\n**Reasoning:** {reasoning}"

        st.markdown(response_text)
        st.session_state.messages.append({"role": "assistant", "content": response_text})

    except Exception as e:
        st.warning(f"ASSESS_FRAUD_RISK function unavailable ({e}). Using LLM fallback.")
        fallback_prompt = (
            f"You are an insurance fraud analyst. Analyze these claim details for red flags.\n\n"
            f"{combined}\n\n"
            f"Return your assessment with: risk score (1-10), red flags found, "
            f"recommendation (approve/investigate/deny), and reasoning."
        )
        fallback = llm_complete(fallback_prompt)
        st.markdown(fallback)
        st.session_state.messages.append({"role": "assistant", "content": fallback})


def classify_document(doc_text, user_prompt):
    escaped = doc_text.replace("'", "''").replace("$$", "$ $")
    try:
        result = session.sql(f"""
            SELECT SENTINEL_DB.CLAIMS.CLASSIFY_DOCUMENT($${escaped}$$) AS classification
        """).to_pandas()
        classification = result['CLASSIFICATION'][0]

        if isinstance(classification, str):
            cls_json = json.loads(classification)
        else:
            cls_json = classification

        label = cls_json.get('label', 'Unknown')
        score = cls_json.get('score', 0)
        try:
            score = float(score)
        except (ValueError, TypeError):
            score = 0.0

        response_text = f"""### Document Classification Result

**Type:** {label}
**Confidence:** {score:.1%}
"""
        st.markdown(response_text)
        st.session_state.messages.append({"role": "assistant", "content": response_text})

    except Exception as e:
        st.warning(f"CLASSIFY_DOCUMENT function unavailable ({e}). Using LLM fallback.")
        fallback_prompt = (
            f"Classify this insurance document into one of these categories: "
            f"Insurance Claim Form, Medical Bill, Invoice, Police Report, Policy Document, Correspondence.\n\n"
            f"Document: {doc_text}\n\n"
            f"Return the category and your confidence level."
        )
        fallback = llm_complete(fallback_prompt)
        st.markdown(fallback)
        st.session_state.messages.append({"role": "assistant", "content": fallback})


def save_feedback(request_id, question, response_text, is_positive, notes=""):
    escaped_q = question.replace("'", "''")[:1000]
    escaped_r = response_text.replace("'", "''")[:2000]
    escaped_n = notes.replace("'", "''")[:500]
    try:
        session.sql(f"""
            INSERT INTO SENTINEL_DB.APPS.AGENT_FEEDBACK
                (request_id, question, response_text, is_positive, feedback_notes)
            VALUES
                ('{request_id}', '{escaped_q}', '{escaped_r}', {is_positive}, '{escaped_n}')
        """).collect()
        return True
    except Exception:
        return False


def render_feedback(msg_index, question, response_text):
    col_up, col_down, col_space = st.columns([1, 1, 8])
    request_id = f"msg-{msg_index}"
    fb_key = f"feedback_{msg_index}"

    if fb_key in st.session_state:
        st.caption(f"Feedback recorded: {'Positive' if st.session_state[fb_key] else 'Negative'}")
        return

    with col_up:
        if st.button("👍", key=f"up_{msg_index}"):
            if save_feedback(request_id, question, response_text, True):
                st.session_state[fb_key] = True
                st.rerun()
    with col_down:
        if st.button("👎", key=f"down_{msg_index}"):
            if save_feedback(request_id, question, response_text, False):
                st.session_state[fb_key] = False
                st.rerun()


def route_and_respond(user_prompt):
    routing_prompt = f"{SYSTEM_PROMPT}\n\nUser question: {user_prompt}"
    action = llm_route(routing_prompt)
    action_type = action.get("type", "text")

    if action_type == "sql":
        sql = action["sql"]
        explanation = action.get("explanation") or ""
        if explanation:
            st.markdown(f"**{explanation}**")
        st.code(sql, language="sql")
        try:
            df = session.sql(sql).to_pandas()
            st.dataframe(df, use_container_width=True)

            data_summary = df.head(20).to_string()
            analysis_prompt = (
                f"You are Cortex Sentinel. The user asked: '{user_prompt}'\n"
                f"Here are the query results:\n{data_summary}\n\n"
                f"Provide a concise, insightful analysis of these results."
            )
            analysis = llm_complete(analysis_prompt)
            st.markdown(analysis)

            st.session_state.messages.append({
                "role": "assistant", "type": "sql_result",
                "sql": sql, "data": df,
                "content": f"Query returned {len(df)} rows",
                "analysis": analysis
            })
        except Exception as e:
            st.error(f"Query error: {e}")
            fix_prompt = (
                f"{SYSTEM_PROMPT}\n\nThe previous SQL failed with error: {e}\n"
                f"Original question: {user_prompt}\n"
                f"Failed SQL: {sql}\n\n"
                f"Generate a corrected SQL query. Return ONLY JSON: {{\"type\": \"sql\", \"sql\": \"<corrected>\"}}"
            )
            retry = llm_route(fix_prompt)
            if retry.get("type") == "sql" and retry.get("sql"):
                st.info("Retrying with corrected query...")
                retry_sql = retry["sql"]
                st.code(retry_sql, language="sql")
                try:
                    df = session.sql(retry_sql).to_pandas()
                    st.dataframe(df, use_container_width=True)
                    st.session_state.messages.append({
                        "role": "assistant", "type": "sql_result",
                        "sql": retry_sql, "data": df,
                        "content": f"Query returned {len(df)} rows"
                    })
                except Exception:
                    st.error("Could not auto-fix the query. Please rephrase your question.")

    elif action_type == "search":
        search_query = action.get("query") or user_prompt
        results = cortex_search(search_query)
        if results:
            context_texts = [r.get("CHUNK_TEXT", "") for r in results]
            context = "\n\n---\n\n".join(context_texts)
            answer_prompt = (
                f"You are Cortex Sentinel. The user asked: '{user_prompt}'\n\n"
                f"Here are relevant policy/guideline excerpts:\n{context}\n\n"
                f"Answer the question based on these documents. Cite the source filename when possible."
            )
            answer = llm_complete(answer_prompt)
            st.markdown(answer)
            with st.expander("📄 Source Documents"):
                for r in results:
                    st.markdown(f"**{r.get('FILENAME', 'Unknown')}**")
                    st.caption(r.get("CHUNK_TEXT", "")[:300] + "...")
            st.session_state.messages.append({"role": "assistant", "content": answer})
        else:
            st.warning("No relevant documents found.")

    elif action_type == "fraud":
        claim_no = action.get("claim_no") or extract_claim_no(user_prompt)
        concern = action.get("concern") or user_prompt
        assess_fraud(claim_no, concern, user_prompt)

    elif action_type == "classify":
        doc_text = action.get("document_text") or user_prompt
        classify_document(doc_text, user_prompt)

    elif action_type == "text":
        text = action.get("text") or ""
        st.markdown(text)
        st.session_state.messages.append({"role": "assistant", "content": text})

    elif action_type == "raw":
        st.markdown(action.get("text", "I couldn't process that request. Please try rephrasing."))
        st.session_state.messages.append({"role": "assistant", "content": action.get("text", "")})


prompt = st.chat_input("Ask Cortex Sentinel about claims, policies, or compliance...")
if hasattr(st.session_state, 'pending_question'):
    prompt = st.session_state.pending_question
    del st.session_state.pending_question

if prompt:
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        with st.spinner("Cortex Sentinel is analyzing..."):
            route_and_respond(prompt)

    msg_idx = len(st.session_state.messages) - 1
    last_msg = st.session_state.messages[msg_idx]
    render_feedback(msg_idx, prompt, last_msg.get("content", "")[:2000])
