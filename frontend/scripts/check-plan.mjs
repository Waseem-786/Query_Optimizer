import oracledb from "oracledb";
const conn = await oracledb.getConnection({
  user: "FLEXCUBE", password: "flexcube",
  connectString: "172.20.3.77:1521/FCUBS",
});

const r = await conn.execute(
  `SELECT id, status, error_message, DBMS_LOB.GETLENGTH(plan_output) plen,
          DBMS_LOB.GETLENGTH(query_text) qlen,
          DBMS_LOB.GETLENGTH(analysis_json) ajen
     FROM query_plan_log WHERE id = 119`,
);
console.log("row 119:", r.rows);

const r2 = await conn.execute(
  `SELECT id, status,
          DBMS_LOB.GETLENGTH(plan_output) plen,
          DBMS_LOB.SUBSTR(query_text, 80, 1) qhead
     FROM query_plan_log
    WHERE id BETWEEN 110 AND 120 ORDER BY id`,
);
console.log("recent rows 110..120:");
for (const row of r2.rows) console.log(" ", row);

// Show plan_output if it exists for any recent row
const r3 = await conn.execute(
  `SELECT id, plan_output FROM query_plan_log
    WHERE id BETWEEN 110 AND 120 AND plan_output IS NOT NULL`,
);
console.log("plans present:");
for (const row of r3.rows) {
  const id = row[0];
  const lob = row[1];
  let text = "";
  if (lob) {
    text = await new Promise((res) => {
      const chunks = [];
      lob.setEncoding("utf8");
      lob.on("data", (c) => chunks.push(c));
      lob.on("end", () => res(chunks.join("")));
    });
  }
  console.log(`  id=${id} plan_len=${text.length} first120=${text.slice(0, 120)}`);
}

await conn.close();
