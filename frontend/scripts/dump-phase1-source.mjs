import oracledb from "oracledb";
const conn = await oracledb.getConnection({
  user: "FLEXCUBE", password: "flexcube",
  connectString: "172.20.3.77:1521/FCUBS",
});

const r = await conn.execute(
  `SELECT line, text FROM user_source
    WHERE name = 'QUERY_ANALYZER_PKG' AND type = 'PACKAGE BODY'
      AND (text LIKE '%INSERT%query_plan_log%' OR text LIKE '%c_status_err%' OR text LIKE '%error_message%')
    ORDER BY line`,
);
console.log("INSERT-related lines in deployed QUERY_ANALYZER_PKG body:");
for (const row of r.rows) {
  console.log(`  L${row[0]}: ${row[1].trimEnd()}`);
}
await conn.close();
