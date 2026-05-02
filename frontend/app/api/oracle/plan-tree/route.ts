import { NextRequest, NextResponse } from "next/server";
import { openConnection, safeClose, OracleRouteError, OracleCreds } from "@/lib/oracle";

interface PlanTreeRequest {
  connection: OracleCreds;
  query: string;
}

interface PlanNode {
  id: number;
  parent_id: number | null;
  depth: number;
  position: number | null;
  operation: string;
  options: string | null;
  object_owner: string | null;
  object_name: string | null;
  object_type: string | null;
  cost: number | null;
  cardinality: number | null;
  bytes: number | null;
  cpu_cost: number | null;
  io_cost: number | null;
  partition_start: string | null;
  partition_stop: string | null;
  access_predicates: string | null;
  filter_predicates: string | null;
  projection: string | null;
  time: number | null;
  qblock_name: string | null;
}

// Returns the EXPLAIN PLAN as a structured tree of nodes (id + parent_id) the
// frontend can render as a flowchart. We run EXPLAIN PLAN under a unique
// statement_id so concurrent requests don't trample each other, then read
// PLAN_TABLE rows directly (richer than DBMS_XPLAN text — we get predicates,
// projection, partition info, CPU vs IO cost split).
//
// PLAN_TABLE rows are best-effort cleaned up afterwards. Worst case they
// linger and get garbage-collected by the next caller using the same id (we
// always DELETE on the way in).
export async function POST(req: NextRequest) {
  let conn = null;
  try {
    const { connection, query } = (await req.json()) as PlanTreeRequest;
    if (!query?.trim()) {
      return NextResponse.json({ error: "Query is required." }, { status: 400 });
    }

    // Reject anything that isn't a SELECT-shape — we never want to EXPLAIN a
    // DML/DDL statement. Mirrors the rule engine's gate.
    const head = query.trim().slice(0, 200).toUpperCase();
    if (!head.startsWith("SELECT") && !head.startsWith("WITH")) {
      return NextResponse.json(
        { error: "Only SELECT / WITH queries can be plan-explained." },
        { status: 400 },
      );
    }

    conn = await openConnection(connection);

    const stmtId =
      "QM_" +
      Math.random().toString(36).slice(2, 8) +
      "_" +
      Date.now().toString(36);

    try {
      await conn.execute(`DELETE FROM plan_table WHERE statement_id = :id`, { id: stmtId });
      await conn.execute(`EXPLAIN PLAN SET STATEMENT_ID = '${stmtId}' FOR ${query}`);

      const rows = await conn.execute<[
        number,                  // id
        number | null,           // parent_id
        number | null,           // depth
        number | null,           // position
        string,                  // operation
        string | null,           // options
        string | null,           // object_owner
        string | null,           // object_name
        string | null,           // object_type
        number | null,           // cost
        number | null,           // cardinality
        number | null,           // bytes
        number | null,           // cpu_cost
        number | null,           // io_cost
        string | null,           // partition_start
        string | null,           // partition_stop
        string | null,           // access_predicates  (CLOB? varchar2)
        string | null,           // filter_predicates
        string | null,           // projection
        number | null,           // time
        string | null,           // qblock_name
      ]>(
        `SELECT id, parent_id, depth, position, operation, options,
                object_owner, object_name, object_type,
                cost, cardinality, bytes, cpu_cost, io_cost,
                partition_start, partition_stop,
                access_predicates, filter_predicates, projection,
                time, qblock_name
           FROM plan_table
          WHERE statement_id = :id
          ORDER BY id`,
        { id: stmtId },
      );

      const tree: PlanNode[] = (rows.rows ?? []).map((r) => ({
        id: r[0],
        parent_id: r[1],
        depth: r[2] ?? 0,
        position: r[3],
        operation: r[4],
        options: r[5],
        object_owner: r[6],
        object_name: r[7],
        object_type: r[8],
        cost: r[9],
        cardinality: r[10],
        bytes: r[11],
        cpu_cost: r[12],
        io_cost: r[13],
        partition_start: r[14],
        partition_stop: r[15],
        access_predicates: r[16],
        filter_predicates: r[17],
        projection: r[18],
        time: r[19],
        qblock_name: r[20],
      }));

      // Cleanup
      try {
        await conn.execute(`DELETE FROM plan_table WHERE statement_id = :id`, { id: stmtId });
        await conn.commit();
      } catch { /* best effort */ }

      return NextResponse.json({ nodes: tree });
    } catch (err) {
      // Try to clean up plan_table even on failure
      try { await conn.execute(`DELETE FROM plan_table WHERE statement_id = :id`, { id: stmtId }); } catch {}
      throw err;
    }
  } catch (err) {
    if (err instanceof OracleRouteError) {
      return NextResponse.json({ error: err.message, code: err.code }, { status: err.status });
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    return NextResponse.json({ error: msg }, { status: 500 });
  } finally {
    await safeClose(conn);
  }
}
