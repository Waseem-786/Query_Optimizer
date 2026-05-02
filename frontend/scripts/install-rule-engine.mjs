// Recompile RULE_ENGINE_PKG and reseed OPTIMIZATION_RULES against a live Oracle.
// Reads SQL files relative to repo root. Run from frontend/ via:
//   node scripts/install-rule-engine.mjs <user> <password> <host:port/service>
//
// Example:
//   node scripts/install-rule-engine.mjs flexcube flexcube 172.20.3.77:1521/FCUBS

import oracledb from "oracledb";
import fs from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SQL_DIR = path.resolve(__dirname, "../../sql");

// Split a script into individual top-level PL/SQL statements.
// Rules:
//   - "/" alone on a line ends a PL/SQL block (CREATE PACKAGE, anonymous BEGIN ...)
//   - ";" at the end of a line ends a plain SQL statement (INSERT, DELETE, ALTER ...)
// We honour those exactly the way SQL*Plus does for these scripts.
function splitScript(sql) {
  const stmts = [];
  let buf = [];
  let inPlsql = false;
  const lines = sql.split(/\r?\n/);
  for (const raw of lines) {
    const line = raw.trimEnd();
    // Drop SQL*Plus directives outright
    if (/^\s*(PROMPT|SET|SHOW|@@|@)\b/i.test(line)) continue;

    // Detect entry into a PL/SQL block
    if (
      /^\s*(CREATE\s+(OR\s+REPLACE\s+)?(PACKAGE|FUNCTION|PROCEDURE|TRIGGER)\b|DECLARE\b|BEGIN\b)/i.test(
        line,
      )
    ) {
      inPlsql = true;
    }

    if (inPlsql) {
      if (/^\s*\/\s*$/.test(line)) {
        // End of PL/SQL block
        const text = buf.join("\n").trim();
        if (text) stmts.push({ kind: "plsql", text });
        buf = [];
        inPlsql = false;
      } else {
        buf.push(line);
      }
    } else {
      buf.push(line);
      if (/;\s*$/.test(line)) {
        const text = buf.join("\n").replace(/;\s*$/, "").trim();
        if (text) stmts.push({ kind: "sql", text });
        buf = [];
      }
    }
  }
  // Flush any trailing buffer (handles files without a final / or ;)
  const tail = buf.join("\n").trim();
  if (tail) {
    stmts.push({ kind: inPlsql ? "plsql" : "sql", text: tail.replace(/;\s*$/, "") });
  }
  return stmts;
}

async function runFile(conn, fname) {
  const sql = await fs.readFile(path.join(SQL_DIR, fname), "utf8");
  const stmts = splitScript(sql);
  console.log(`\n=== ${fname} (${stmts.length} statement(s)) ===`);
  let i = 0;
  for (const stmt of stmts) {
    i++;
    const head = stmt.text.split("\n").slice(0, 1).join("").slice(0, 80);
    try {
      await conn.execute(stmt.text);
      console.log(`  [${i}] OK  ${head}`);
    } catch (err) {
      console.error(`  [${i}] FAIL ${head}`);
      console.error(`       ${err.message}`);
      throw err;
    }
  }
}

async function main() {
  const [user, password, connectString] = process.argv.slice(2);
  if (!user || !password || !connectString) {
    console.error("usage: node install-rule-engine.mjs <user> <password> <host:port/service>");
    process.exit(2);
  }

  const conn = await oracledb.getConnection({ user, password, connectString });
  console.log(`Connected to ${connectString} as ${user}`);
  try {
    await runFile(conn, "06_seed_optimization_rules.sql");
    await runFile(conn, "07_create_rule_engine_spec.sql");
    await runFile(conn, "08_create_rule_engine_body.sql");
    await conn.commit();

    // Sanity: package status + rule count
    const pkg = await conn.execute(
      `SELECT object_name, status FROM user_objects
        WHERE object_name = 'RULE_ENGINE_PKG'
        ORDER BY object_type`,
    );
    console.log("\nPackage status:");
    for (const r of pkg.rows ?? []) console.log(`  ${r[0]} -> ${r[1]}`);

    const rules = await conn.execute(`SELECT COUNT(*) FROM optimization_rules`);
    console.log(`\nRules in catalogue: ${rules.rows?.[0]?.[0]}`);

    // Show errors if compilation failed
    const errs = await conn.execute(
      `SELECT name, type, line, position, text
         FROM user_errors
        WHERE name = 'RULE_ENGINE_PKG'
        ORDER BY sequence`,
    );
    if ((errs.rows ?? []).length) {
      console.log("\nCompile errors:");
      for (const r of errs.rows) {
        console.log(`  ${r[1]} line ${r[2]} col ${r[3]}: ${r[4]}`);
      }
      process.exit(1);
    }
    console.log("\nAll done. RULE_ENGINE_PKG compiled clean.");
  } finally {
    await conn.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
