import { NextRequest, NextResponse } from "next/server";
import oracledb from "oracledb";
import { openConnection, safeClose, readClob, parseOracleJson, OracleRouteError, OracleCreds } from "@/lib/oracle";

interface BenchmarkRequest {
  connection: OracleCreds;
  originalQuery: string;
  optimizedQueries: string[];
  iterations?: number;
}

interface BenchmarkEntry {
  label: string;
  is_valid: "Y" | "N";
  validation_msg: string;
  result_row_count: number;
  results_match: "YES" | "NO" | "ROW_COUNT" | "N/A";
  diff_row_count: number;
  avg_exec_ms: number | null;
  min_exec_ms: number | null;
  max_exec_ms: number | null;
  benchmark_id: number | null;
}

interface BenchmarkReport {
  status: string;
  message?: string;
  version?: string;
  decision?: "ORIGINAL_FASTEST" | "OPTIMIZED_SELECTED" | "NO_VALID_QUERY";
  winner?: string;
  speedup_factor?: number;
  original_avg_ms?: number;
  iterations_run?: number;
  reasoning?: string;
  benchmarks?: BenchmarkEntry[];
}

export async function POST(req: NextRequest) {
  let conn = null;
  try {
    const { connection, originalQuery, optimizedQueries, iterations } = (await req.json()) as BenchmarkRequest;

    if (!originalQuery?.trim()) {
      return NextResponse.json({ error: "Original query is required." }, { status: 400 });
    }
    if (!Array.isArray(optimizedQueries) || optimizedQueries.length === 0) {
      return NextResponse.json({ error: "At least one optimized query is required." }, { status: 400 });
    }

    const iters = Math.max(1, Math.min(5, Number(iterations) || 3));
    conn = await openConnection(connection);

    // Build an inline PL/SQL block because validate_and_benchmark takes
    // an associative-array (query_list_t) OF CLOB which node-oracledb
    // cannot bind directly. We generate :q1, :q2 … bindvars.
    const assignLines = optimizedQueries.map((_, i) => `  l_queries(${i + 1}) := :q${i + 1};`).join("\n");
    const plsql = `
      DECLARE
        l_queries VALIDATION_ENGINE_PKG.QUERY_LIST_T;
      BEGIN
${assignLines}
        VALIDATION_ENGINE_PKG.VALIDATE_AND_BENCHMARK(
          p_original_query    => :orig,
          p_optimized_queries => l_queries,
          p_iterations        => :iters,
          p_result            => :result
        );
      END;
    `;

    const binds: Record<string, oracledb.BindParameter> = {
      orig:   { val: originalQuery, dir: oracledb.BIND_IN,  type: oracledb.CLOB },
      iters:  { val: iters,        dir: oracledb.BIND_IN,  type: oracledb.NUMBER },
      result: { dir: oracledb.BIND_OUT, type: oracledb.CLOB },
    };
    optimizedQueries.forEach((q, i) => {
      binds[`q${i + 1}`] = { val: q, dir: oracledb.BIND_IN, type: oracledb.CLOB };
    });

    const result = await conn.execute(plsql, binds);
    const outLob = (result.outBinds as { result: oracledb.Lob }).result;
    const raw = await readClob(outLob);
    const report = parseOracleJson<BenchmarkReport>(raw);

    if (report.status && report.status !== "SUCCESS") {
      return NextResponse.json(
        { error: report.message ?? "Benchmark failed.", report },
        { status: 400 }
      );
    }

    return NextResponse.json(report);
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
