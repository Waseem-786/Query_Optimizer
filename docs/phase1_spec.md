# 📘 Phase 1 Specification — AI-Powered SQL Query Optimizer

> **Database-Native Query Analysis Engine**

## 1. 🎯 Phase Objective

Build a Database-Native Query Analysis Engine that:
- Accepts an SQL query as input
- Executes an execution plan analysis (without running the query)
- Extracts key performance metrics
- Returns a structured performance report

**👉 Phase 1 is analysis only — no optimization or rewriting.**

---

## 2. 🏗️ Scope

### ✅ Included
- Query input interface (Stored Procedure)
- Execution plan generation via `EXPLAIN PLAN`
- Execution plan parsing and metric extraction
- Basic performance insights and observations
- Structured JSON output
- Audit logging to `QUERY_PLAN_LOG`

### ❌ Not Included
- Query rewriting or optimization
- AI integration
- Index recommendations
- Advanced rule engine

---

## 3. 🗄️ Target Platform

| Component | Technology |
|-----------|------------|
| Database | Oracle Database 12c+ |
| Language | PL/SQL |
| Plan Tool | `DBMS_XPLAN.DISPLAY` |

---

## 4. ⚙️ System Components

### 4.1 Input Interface

```sql
PROCEDURE analyze_query (
    p_query  IN  CLOB,
    p_report OUT CLOB
);
```

### 4.2 Execution Plan Generator

```sql
EXPLAIN PLAN SET STATEMENT_ID = '<unique_id>'
FOR <input_query>;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', '<unique_id>', 'ALL'));
```

### 4.3 Storage — `QUERY_PLAN_LOG`

| Column | Type | Purpose |
|--------|------|---------|
| `id` | NUMBER (identity) | Primary key |
| `query_text` | CLOB | Original query |
| `plan_output` | CLOB | Raw execution plan |
| `analysis_json` | CLOB | Parsed JSON result |
| `status` | VARCHAR2(20) | SUCCESS / ERROR |
| `error_message` | VARCHAR2(4000) | Error details |
| `execution_time` | NUMBER | Analysis time (ms) |
| `created_at` | TIMESTAMP | Request timestamp |

### 4.4 Plan Parser — Extracted Metrics

| Metric | Values |
|--------|--------|
| Scan Type | FULL TABLE SCAN, INDEX RANGE SCAN, INDEX UNIQUE SCAN, etc. |
| Cost | Numeric |
| Rows | Estimated cardinality |
| Index Used | Boolean |
| Join Type | NESTED LOOPS, HASH JOIN, MERGE JOIN, NONE |
| Observations | Array of performance insights |

---

## 5. 🧠 Core Logic Flow

```
1. Accept input query
2. Validate (NULL check, SELECT-only enforcement)
3. Generate EXPLAIN PLAN (dynamic SQL)
4. Fetch plan from DBMS_XPLAN
5. Parse plan output — extract metrics
6. Generate observations
7. Log to QUERY_PLAN_LOG
8. Build structured JSON report
9. Return output
```

---

## 6. 🧪 Functional Requirements

| ID | Requirement |
|----|------------|
| FR-1 | Accept queries up to CLOB size |
| FR-2 | Handle SELECT and WITH (CTE) queries |
| FR-3 | Generate plan without executing query (safe mode) |
| FR-4 | Capture full execution plan text |
| FR-5 | Detect Full Table Scan, Index Scan, Join types |
| FR-6 | Extract cost and row estimates |
| FR-7 | Return structured JSON output with observations |
| FR-8 | Log all analyses to audit table |

---

## 7. ⚠️ Error Handling

| Condition | Status | Message |
|-----------|--------|---------|
| NULL/empty input | ERROR | `Query input is NULL or empty` |
| Non-SELECT query | ERROR | `Only SELECT queries are supported in Phase 1` |
| DML/DDL detected | ERROR | `DML/DDL statements are not allowed` |
| Invalid SQL | ERROR | `Failed to generate execution plan: <details>` |
| Plan failure | ERROR | `Failed to retrieve execution plan: <details>` |

---

## 8. 📊 Non-Functional Requirements

- **Performance:** Plan generation < 2 seconds
- **Security:** Prevent SQL injection; restrict DML/DDL
- **Scalability:** Logging supports large query volumes
- **Auditability:** Every analysis request is persisted

---

## 9. ✅ Acceptance Criteria

Phase 1 is complete when:

- ✔ Query input is accepted and validated
- ✔ Execution plan is generated safely
- ✔ Key metrics are extracted (scan type, cost, rows, index, joins)
- ✔ Structured JSON report is returned
- ✔ Errors are handled properly with appropriate messages
- ✔ All analyses are logged to `QUERY_PLAN_LOG`

---

## 10. 🔜 Next Phase (Phase 2 Preview)

- Rule-based optimization engine
- Query improvement suggestions
- Index detection and recommendation engine
