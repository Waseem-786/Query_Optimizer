import oracledb from "oracledb";
const conn = await oracledb.getConnection({
  user: "FLEXCUBE", password: "flexcube",
  connectString: "172.20.3.77:1521/FCUBS",
});

// Simulate exactly what Phase 1's outer EXCEPTION-OTHERS does
const r = await conn.execute(
  `DECLARE
     l_v   VARCHAR2(2);
     l_id  NUMBER;
     l_msg VARCHAR2(4000);
   BEGIN
     BEGIN
       l_v := 'ABCDE';   -- raises ORA-06502
     EXCEPTION
       WHEN OTHERS THEN
         l_msg := SQLERRM;
         INSERT INTO query_plan_log (query_text, status, error_message)
         VALUES ('-- probe', 'ERROR', l_msg)
         RETURNING id INTO l_id;
         COMMIT;
         :id := l_id;
     END;
   END;`,
  { id: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER } },
);
const newId = r.outBinds.id;
console.log("Inserted probe row id:", newId);

const r2 = await conn.execute(
  `SELECT id, status, error_message, LENGTH(error_message) ln
     FROM query_plan_log WHERE id = :id`,
  { id: newId },
);
console.log("Probe row from DB:", r2.rows);

// Cleanup
await conn.execute(`DELETE FROM query_plan_log WHERE id = :id`, { id: newId });
await conn.commit();

// Check user_triggers on QUERY_PLAN_LOG
const r3 = await conn.execute(
  `SELECT trigger_name, triggering_event, status
     FROM user_triggers WHERE table_name = 'QUERY_PLAN_LOG'`,
);
console.log("\nTriggers on QUERY_PLAN_LOG:");
for (const row of r3.rows) console.log("  ", row);

await conn.close();
