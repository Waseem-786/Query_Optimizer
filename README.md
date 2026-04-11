# 🚀 AI-Powered SQL Query Optimizer

> **Phase 1 — Database-Native Query Analysis Engine**

An Oracle PL/SQL system that analyzes SQL queries by generating and parsing execution plans, extracting performance metrics, and returning structured JSON reports — all without executing the actual query.

---

## 📋 Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Installation](#installation)
- [Usage](#usage)
- [Output Format](#output-format)
- [Error Handling](#error-handling)
- [Project Structure](#project-structure)
- [Testing](#testing)
- [Roadmap](#roadmap)

---

## ✅ Features

| Feature | Description |
|---------|-------------|
| **Safe Analysis** | Uses `EXPLAIN PLAN` only — never executes the actual query |
| **Scan Detection** | Identifies FULL TABLE SCAN, INDEX RANGE/UNIQUE/FULL SCAN |
| **Join Detection** | Detects NESTED LOOPS, HASH JOIN, MERGE JOIN |
| **Cost Analysis** | Extracts and reports query execution cost |
| **Row Estimation** | Reports estimated cardinality (row count) |
| **Smart Observations** | Auto-generates performance observations and warnings |
| **Audit Logging** | Every analysis is logged to `QUERY_PLAN_LOG` |
| **JSON Output** | Returns structured, machine-readable JSON reports |
| **Input Validation** | Rejects DML/DDL and enforces SELECT-only analysis |

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    ANALYZE_QUERY (Entry Point)               │
├──────────────────────────────────────────────────────────────┤
│  1. validate_query()  →  Reject non-SELECT, NULL, DML/DDL   │
│  2. EXPLAIN PLAN FOR  →  Generate plan via dynamic SQL       │
│  3. DBMS_XPLAN.DISPLAY →  Fetch formatted plan output        │
│  4. PARSE_PLAN()      →  Extract metrics from plan text      │
│  5. Log to QUERY_PLAN_LOG                                    │
│  6. Build & return JSON report                               │
└──────────────────────────────────────────────────────────────┘
```

---

## 📦 Installation

### Prerequisites
- Oracle Database 12c or later (Oracle XE works fine)
- SQL*Plus, SQL Developer, or any Oracle client

### Install

```sql
-- Connect to your Oracle database
sqlplus username/password@//host:port/service

-- Run the master install script
@scripts/install.sql
```

### Setup Test Data (optional)

```sql
@test/01_setup_sample_data.sql
```

### Uninstall

```sql
@sql/04_drop_all.sql
```

---

## 🔧 Usage

### Basic Analysis

```sql
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    l_report CLOB;
BEGIN
    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT * FROM orders WHERE user_id = 10',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
END;
/
```

### View Analysis History

```sql
DECLARE
    l_cursor SYS_REFCURSOR;
    l_id     NUMBER;
    l_query  VARCHAR2(200);
    l_status VARCHAR2(20);
    l_time   NUMBER;
    l_date   TIMESTAMP;
BEGIN
    query_analyzer_pkg.get_analysis_history(
        p_limit  => 5,
        p_result => l_cursor
    );

    LOOP
        FETCH l_cursor INTO l_id, l_query, l_status, l_time, l_date;
        EXIT WHEN l_cursor%NOTFOUND;
        DBMS_OUTPUT.PUT_LINE(l_id || ' | ' || l_status || ' | ' || l_query);
    END LOOP;
    CLOSE l_cursor;
END;
/
```

---

## 📤 Output Format

### Success Response

```json
{
  "status": "SUCCESS",
  "version": "1.0.0",
  "execution_time_ms": 42.5,
  "query": "SELECT * FROM orders WHERE user_id = 10",
  "analysis": {
    "scan_type": "FULL TABLE SCAN",
    "cost": 125,
    "rows": 10000,
    "index_used": false,
    "index_name": "",
    "join_type": "NONE",
    "access_path": "TABLE ACCESS FULL",
    "filter": "",
    "observations": [
      "Full table scan detected",
      "No index usage found — consider adding indexes",
      "Potential missing index on filtered column(s)"
    ]
  }
}
```

### Error Response

```json
{
  "status": "ERROR",
  "message": "Only SELECT queries are supported in Phase 1"
}
```

---

## ⚠️ Error Handling

| Error Case | Response Message |
|------------|-----------------|
| NULL / empty input | `Query input is NULL or empty` |
| Non-SELECT query | `Only SELECT queries are supported in Phase 1` |
| DML/DDL detected | `DML/DDL statements are not allowed — SELECT only` |
| Invalid SQL syntax | `Failed to generate execution plan: <ORA error>` |
| Non-existent table | `Failed to generate execution plan: <ORA error>` |
| Plan retrieval failure | `Failed to retrieve execution plan: <details>` |

---

## 📁 Project Structure

```
Query_Optimizer/
│
├── README.md                            # This file
├── docs/
│   └── phase1_spec.md                   # Phase 1 specification
│
├── sql/                                 # Core database objects
│   ├── 01_create_tables.sql             # QUERY_PLAN_LOG table
│   ├── 02_create_package_spec.sql       # Package specification
│   ├── 03_create_package_body.sql       # Package body (core logic)
│   └── 04_drop_all.sql                  # Cleanup script
│
├── scripts/
│   └── install.sql                      # Master install runner
│
└── test/
    ├── 01_setup_sample_data.sql         # Sample tables & data
    ├── 02_test_analyze_query.sql        # 7 functional tests
    └── 03_test_error_handling.sql        # 9 error handling tests
```

---

## 🧪 Testing

### Run Functional Tests

```sql
-- Setup test data first
@test/01_setup_sample_data.sql

-- Run functional tests (7 test cases)
@test/02_test_analyze_query.sql

-- Run error handling tests (9 test cases)
@test/03_test_error_handling.sql
```

### Test Coverage

| Test Suite | Cases | What's Tested |
|-----------|-------|---------------|
| Functional | 7 | Full scan, index scan, JOIN, subquery, aggregation, multi-join, CTE |
| Error Handling | 9 | NULL, empty, INSERT, UPDATE, DELETE, DROP, invalid SQL, missing table, GRANT |

---

## 🔜 Roadmap

| Phase | Description | Status |
|-------|-------------|--------|
| **Phase 1** | Database-native query analysis engine | ✅ Current |
| **Phase 2** | Rule-based optimization + index recommendations | 🔲 Planned |
| **Phase 3** | AI-powered query rewriting | 🔲 Planned |
| **Phase 4** | Validation engine + result comparison | 🔲 Planned |

---

## 📄 License

Internal project — AI-Powered SQL Query Optimization System.
