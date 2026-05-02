import { NextRequest, NextResponse } from "next/server";
import { openConnection, safeClose, OracleRouteError, OracleCreds } from "@/lib/oracle";

export async function POST(req: NextRequest) {
  let conn = null;
  try {
    const creds = (await req.json()) as OracleCreds;
    conn = await openConnection(creds);
    const row = await conn.execute<[string, string]>(
      `SELECT USER, SYS_CONTEXT('USERENV','DB_NAME') FROM dual`
    );
    const [dbUser, dbName] = (row.rows?.[0] ?? [creds.user, creds.serviceName]);

    return NextResponse.json({
      ok: true,
      user: dbUser,
      db: dbName,
      connectString: `${creds.host}:${creds.port}/${creds.serviceName}`,
    });
  } catch (err) {
    if (err instanceof OracleRouteError) {
      return NextResponse.json({ ok: false, error: err.message, code: err.code }, { status: err.status });
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    return NextResponse.json({ ok: false, error: msg }, { status: 500 });
  } finally {
    await safeClose(conn);
  }
}
