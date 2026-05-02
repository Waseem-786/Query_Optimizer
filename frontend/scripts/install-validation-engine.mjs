// Recompile QUERY_BENCHMARK + VALIDATION_ENGINE_PKG against a live Oracle.
//
//   node scripts/install-validation-engine.mjs <user> <password> <host:port/service>
//
// Drops + recreates QUERY_BENCHMARK (loses history) and recompiles the
// validation_engine_pkg spec + body. Use after the 09/10/11 SQL files change.

import oracledb from "oracledb";
import fs from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SQL_DIR = path.resolve(__dirname, "../../sql");

function splitScript(sql) {
  const stmts = [];
  let buf = [];
  let inPlsql = false;
  for (const raw of sql.split(/\r?\n/)) {
    const line = raw.trimEnd();
    if (/^\s*(PROMPT|SET|SHOW|@@|@)\b/i.test(line)) continue;
    if (/^\s*(CREATE\s+(OR\s+REPLACE\s+)?(PACKAGE|FUNCTION|PROCEDURE|TRIGGER)\b|DECLARE\b|BEGIN\b)/i.test(line)) {
      inPlsql = true;
    }
    if (inPlsql) {
      if (/^\s*\/\s*$/.test(line)) {
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
  const tail = buf.join("\n").trim();
  if (tail) stmts.push({ kind: inPlsql ? "plsql" : "sql", text: tail.replace(/;\s*$/, "") });
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
    console.error("usage: node install-validation-engine.mjs <user> <password> <host:port/service>");
    process.exit(2);
  }
  const conn = await oracledb.getConnection({ user, password, connectString });
  console.log(`Connected to ${connectString} as ${user}`);
  try {
    await runFile(conn, "09_create_benchmark_table.sql");
    await runFile(conn, "10_create_validation_package_spec.sql");
    await runFile(conn, "11_create_validation_package_body.sql");
    await conn.commit();

    const pkg = await conn.execute(
      `SELECT object_name, status FROM user_objects
        WHERE object_name = 'VALIDATION_ENGINE_PKG'
        ORDER BY object_type`,
    );
    console.log("\nPackage status:");
    for (const r of pkg.rows ?? []) console.log(`  ${r[0]} -> ${r[1]}`);

    const errs = await conn.execute(
      `SELECT name, type, line, position, text
         FROM user_errors
        WHERE name = 'VALIDATION_ENGINE_PKG'
        ORDER BY sequence`,
    );
    if ((errs.rows ?? []).length) {
      console.log("\nCompile errors:");
      for (const r of errs.rows) {
        console.log(`  ${r[1]} line ${r[2]} col ${r[3]}: ${r[4]}`);
      }
      process.exit(1);
    }
    console.log("\nAll done. VALIDATION_ENGINE_PKG compiled clean.");
  } finally {
    await conn.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
