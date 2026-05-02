import { NextRequest, NextResponse } from "next/server";
import oracledb from "oracledb";
import { openConnection, safeClose, readClob, parseOracleJson, OracleRouteError, OracleCreds } from "@/lib/oracle";

interface AnalyzeRequest {
  connection: OracleCreds;
  query: string;
}

interface TriggeredRule {
  rule_name: string;
  category: string;
  severity: "HIGH" | "MEDIUM" | "LOW";
  description: string;
  recommendation: string;
  context: string;
  index_recommendation: string | null;
  optimized_fragment: string | null;
}

interface PlanAnalysis {
  scan_type?: string;
  cost?: number;
  rows?: number;
  index_used?: boolean;
  index_name?: string;
  join_type?: string;
  access_path?: string;
  filter?: string;
  observations?: string[];
}

interface OracleAnalyzeReport {
  status: string;
  message?: string;
  version?: string;
  execution_time_ms?: number;
  query_log_id?: number | null;
  query?: string;
  rule_summary?: {
    total_rules_evaluated: number;
    rules_triggered: number;
    high_severity: number;
    medium_severity: number;
    low_severity: number;
  };
  triggered_rules?: TriggeredRule[];
  index_recommendations?: string[];
  plan_analysis?: PlanAnalysis | null;
}

export async function POST(req: NextRequest) {
  let conn = null;
  try {
    const { connection, query } = (await req.json()) as AnalyzeRequest;

    if (!query || !query.trim()) {
      return NextResponse.json({ error: "Query is required." }, { status: 400 });
    }

    conn = await openConnection(connection);

    const result = await conn.execute<Record<string, unknown>>(
      `BEGIN RULE_ENGINE_PKG.APPLY_RULES(p_query => :q, p_report => :r); END;`,
      {
        q: { val: query, dir: oracledb.BIND_IN, type: oracledb.CLOB },
        r: { dir: oracledb.BIND_OUT, type: oracledb.CLOB },
      }
    );

    const reportLob = (result.outBinds as { r: oracledb.Lob }).r;
    const raw = await readClob(reportLob);
    const report = parseOracleJson<OracleAnalyzeReport>(raw);

    if (report.status && report.status !== "SUCCESS") {
      return NextResponse.json(
        { error: report.message ?? "Oracle rejected the query.", report },
        { status: 400 }
      );
    }

    // Fetch raw plan from QUERY_PLAN_LOG for THIS analysis run, by id.
    // Falling back to "most recent SUCCESS" produced wrong results under any
    // concurrency — a parallel call would steal the latest row.
    let rawPlan = "";
    if (report.query_log_id != null) {
      try {
        const planRow = await conn.execute<[oracledb.Lob]>(
          `SELECT plan_output FROM query_plan_log WHERE id = :id`,
          { id: report.query_log_id }
        );
        const planLob = (planRow.rows?.[0]?.[0] as oracledb.Lob | undefined) ?? null;
        rawPlan = await readClob(planLob);
      } catch { /* plan text is best-effort */ }
    }

    return NextResponse.json({ ...report, raw_plan: rawPlan });
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
