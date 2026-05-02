import oracledb from "oracledb";
const conn = await oracledb.getConnection({
  user: "FLEXCUBE", password: "flexcube",
  connectString: "172.20.3.77:1521/FCUBS",
});

// Direct call to Phase 1 (bypass apply_rules) — see if Phase 1 alone fails too
const q = `SELECT * FROM ACTB_HISTORY A,STTM_CUST_ACCOUNT B,STTM_CUSTOMER C
WHERE A.AC_BRANCH=B.BRANCH_CODE AND A.AC_NO=B.CUST_AC_NO AND B.CUST_NO=C.CUSTOMER_NO
AND C.CUSTOMER_TYPE='I' AND B.RECORD_STAT='O' AND B.CUST_AC_nO IN (SELECT ACC FROM ACTB_ACC_BAL_STAT_CUSTOM)`;

const r = await conn.execute(
  `BEGIN query_analyzer_pkg.analyze_query(p_query => :q, p_report => :r); END;`,
  {
    q: { val: q, dir: oracledb.BIND_IN, type: oracledb.CLOB },
    r: { dir: oracledb.BIND_OUT, type: oracledb.CLOB },
  },
);
const lob = r.outBinds.r;
let txt = "";
if (lob) {
  txt = await new Promise((res) => {
    const cs = []; lob.setEncoding("utf8");
    lob.on("data", (c) => cs.push(c));
    lob.on("end", () => res(cs.join("")));
  });
}
console.log("Phase 1 report (first 600 chars):");
console.log(txt.slice(0, 600));
console.log("...");
console.log("[length=" + txt.length + "]");

// Also fetch the very latest row to confirm what got inserted
const r2 = await conn.execute(
  `SELECT id, status, error_message, LENGTH(error_message) err_len,
          DBMS_LOB.GETLENGTH(plan_output) plen
     FROM (SELECT id, status, error_message, plan_output FROM query_plan_log ORDER BY id DESC)
    WHERE ROWNUM = 1`,
);
console.log("\nLatest query_plan_log row (with err_len):");
console.log(r2.rows);

// Sample any old row with descriptive error_message to confirm column writes work
const r3 = await conn.execute(
  `SELECT id, status, error_message, LENGTH(error_message) ln
     FROM query_plan_log
    WHERE error_message IS NOT NULL AND LENGTH(error_message) > 5
    ORDER BY id DESC FETCH FIRST 3 ROWS ONLY`,
);
console.log("\nRecent rows with longer error_message (proves column writes work):");
console.log(r3.rows);
// Inspect table structure
const r4 = await conn.execute(
  `SELECT column_name, data_type, data_length, column_id
     FROM user_tab_columns WHERE table_name = 'QUERY_PLAN_LOG'
     ORDER BY column_id`,
);
console.log("\nQUERY_PLAN_LOG columns:");
for (const row of r4.rows) console.log("  ", row);

// Test SQLERRM directly via a tiny anon block that raises ORA-06502
const r5 = await conn.execute(
  `DECLARE
     l_v VARCHAR2(2);
     l_msg VARCHAR2(4000);
   BEGIN
     BEGIN
       l_v := 'ABCDE';  -- forces ORA-06502
     EXCEPTION
       WHEN OTHERS THEN l_msg := SQLERRM;
     END;
     :out := l_msg;
   END;`,
  { out: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 4000 } },
);
console.log("\nSanity SQLERRM check (should print full ORA-06502 message):");
console.log("  ", r5.outBinds.out);

await conn.close();
