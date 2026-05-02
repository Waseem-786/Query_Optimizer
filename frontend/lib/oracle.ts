import oracledb from "oracledb";

export interface OracleCreds {
  host: string;
  port: number | string;
  serviceName: string;
  user: string;
  password: string;
}

export class OracleRouteError extends Error {
  status: number;
  code?: string;
  constructor(message: string, status = 500, code?: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function connectString({ host, port, serviceName }: OracleCreds) {
  return `${host}:${port}/${serviceName}`;
}

export async function openConnection(creds: OracleCreds): Promise<oracledb.Connection> {
  if (!creds?.host || !creds?.port || !creds?.serviceName || !creds?.user || !creds?.password) {
    throw new OracleRouteError("Database connection details are missing or incomplete.", 400, "BAD_CREDS");
  }
  try {
    return await oracledb.getConnection({
      user: creds.user,
      password: creds.password,
      connectString: connectString(creds),
    });
  } catch (err: unknown) {
    const e = err as { errorNum?: number; message?: string };
    const msg = e?.message || "Unable to reach the Oracle database.";
    const code = e?.errorNum ? `ORA-${String(e.errorNum).padStart(5, "0")}` : "CONN_FAIL";
    throw new OracleRouteError(msg, 503, code);
  }
}

export async function readClob(lob: oracledb.Lob | null | undefined): Promise<string> {
  if (!lob) return "";
  return new Promise<string>((resolve, reject) => {
    const chunks: string[] = [];
    lob.setEncoding("utf8");
    lob.on("data", (chunk: string) => chunks.push(chunk));
    lob.on("end", () => resolve(chunks.join("")));
    lob.on("error", reject);
  });
}

export function parseOracleJson<T = unknown>(raw: string): T {
  if (!raw) throw new OracleRouteError("Oracle returned an empty response.", 500, "EMPTY");
  try {
    return JSON.parse(raw) as T;
  } catch {
    throw new OracleRouteError(
      "Failed to parse JSON returned by the Oracle package: " + raw.slice(0, 200),
      500,
      "BAD_JSON"
    );
  }
}

export async function safeClose(conn: oracledb.Connection | null) {
  if (!conn) return;
  try { await conn.close(); } catch { /* ignore close errors */ }
}
