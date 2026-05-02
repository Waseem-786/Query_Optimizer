import { NextRequest, NextResponse } from "next/server";
import { openConnection, safeClose, OracleRouteError, OracleCreds } from "@/lib/oracle";

interface SchemaRequest {
  connection: OracleCreds;
  tables: string[];
}

interface IndexMeta {
  name: string;
  unique: boolean;
  columns: string[];
}

interface ColumnMeta {
  name: string;
  type: string;          // e.g. "VARCHAR2(20)", "NUMBER(10,2)", "DATE"
  nullable: boolean;
  num_distinct: number | null;   // NDV — selectivity hint
  num_nulls: number | null;
  density: number | null;        // 1 / NDV approximately
}

interface ForeignKeyMeta {
  name: string;
  columns: string[];             // child columns on this table
  references_table: string;
  references_columns: string[];
}

interface TableMeta {
  name: string;
  owner: string | null;
  rows: number | null;
  blocks: number | null;
  avg_row_len: number | null;
  last_analyzed: string | null;
  partitioned: boolean;
  primary_key: string[];
  unique_keys: string[][];       // list of UK column groups (each UK is a column list)
  foreign_keys: ForeignKeyMeta[];
  indexes: IndexMeta[];
  columns: ColumnMeta[];
}

// Pulls comprehensive per-table metadata for the AI rewrite pipeline:
//   • Table size (NUM_ROWS, BLOCKS, AVG_ROW_LEN, LAST_ANALYZED, partitioned).
//   • Full column list with data type + length/precision, nullability,
//     and column-level stats (NUM_DISTINCT / NUM_NULLS / DENSITY) so the
//     LLM can reason about predicate selectivity.
//   • Primary key, every unique key, and every foreign key (with the
//     referenced table + columns) — surfaces real relationships.
//   • Every index with its column list in leading-column order.
//
// All reads use ALL_* views so cross-schema visibility works for the
// connecting user. We pick the OWNER row with the highest NUM_ROWS to
// avoid stale empty replicas in other schemas.
export async function POST(req: NextRequest) {
  let conn = null;
  try {
    const { connection, tables } = (await req.json()) as SchemaRequest;
    if (!Array.isArray(tables) || tables.length === 0) {
      return NextResponse.json({ tables: [] });
    }

    const wanted = Array.from(
      new Set(
        tables
          .map((t) => (t || "").trim().toUpperCase())
          .filter((t) => /^[A-Z][A-Z0-9_$#]*$/.test(t)),
      ),
    );
    if (wanted.length === 0) return NextResponse.json({ tables: [] });

    conn = await openConnection(connection);

    const result: TableMeta[] = [];
    for (const tbl of wanted) {
      const meta: TableMeta = {
        name: tbl,
        owner: null,
        rows: null,
        blocks: null,
        avg_row_len: null,
        last_analyzed: null,
        partitioned: false,
        primary_key: [],
        unique_keys: [],
        foreign_keys: [],
        indexes: [],
        columns: [],
      };

      // 1) Pick best OWNER row + table-level stats.
      try {
        const r = await conn.execute<[string, number | null, number | null, number | null, Date | null, string | null]>(
          `SELECT owner, num_rows, blocks, avg_row_len, last_analyzed, partitioned
             FROM (SELECT owner, num_rows, blocks, avg_row_len, last_analyzed, partitioned
                     FROM all_tables
                    WHERE table_name = :t
                    ORDER BY NVL(num_rows, 0) DESC NULLS LAST)
            WHERE ROWNUM = 1`,
          { t: tbl },
        );
        const row = r.rows?.[0];
        if (row) {
          meta.owner = row[0];
          meta.rows = row[1] ?? null;
          meta.blocks = row[2] ?? null;
          meta.avg_row_len = row[3] ?? null;
          meta.last_analyzed = row[4] ? row[4].toISOString().slice(0, 10) : null;
          meta.partitioned = row[5] === "YES";
        } else continue;
      } catch { continue; }

      // 2) Columns with type + nullability + per-column stats (joined in one shot).
      try {
        const cols = await conn.execute<
          [string, string, number | null, number | null, string, number | null, number | null, number | null]
        >(
          `SELECT c.column_name,
                  c.data_type,
                  c.data_length,
                  c.data_precision,
                  c.nullable,
                  s.num_distinct,
                  s.num_nulls,
                  s.density
             FROM all_tab_columns c
             LEFT JOIN all_tab_col_statistics s
               ON s.owner       = c.owner
              AND s.table_name  = c.table_name
              AND s.column_name = c.column_name
            WHERE c.owner = :o AND c.table_name = :t
            ORDER BY c.column_id
            FETCH FIRST 200 ROWS ONLY`,
          { o: meta.owner, t: tbl },
        );
        meta.columns = (cols.rows ?? []).map((r) => {
          const [name, type, len, prec, nullable, ndv, nulls, density] = r;
          let typeStr = type;
          if (type === "VARCHAR2" || type === "CHAR" || type === "NVARCHAR2" || type === "NCHAR") {
            if (len != null) typeStr = `${type}(${len})`;
          } else if (type === "NUMBER" && prec != null) {
            typeStr = `NUMBER(${prec})`;
          }
          return {
            name,
            type: typeStr,
            nullable: nullable === "Y",
            num_distinct: ndv,
            num_nulls: nulls,
            density,
          };
        });
      } catch { /* leave empty */ }

      // 3) Primary key columns.
      try {
        const pk = await conn.execute<[string]>(
          `SELECT cc.column_name
             FROM all_constraints c
             JOIN all_cons_columns cc
               ON cc.constraint_name = c.constraint_name AND cc.owner = c.owner
            WHERE c.owner = :o AND c.table_name = :t AND c.constraint_type = 'P'
            ORDER BY cc.position`,
          { o: meta.owner, t: tbl },
        );
        meta.primary_key = (pk.rows ?? []).map((r) => r[0]);
      } catch { /* leave empty */ }

      // 4) Unique-key constraints (grouped by constraint name).
      try {
        const uk = await conn.execute<[string, string]>(
          `SELECT c.constraint_name,
                  LISTAGG(cc.column_name, ',')
                    WITHIN GROUP (ORDER BY cc.position) AS cols
             FROM all_constraints c
             JOIN all_cons_columns cc
               ON cc.constraint_name = c.constraint_name AND cc.owner = c.owner
            WHERE c.owner = :o AND c.table_name = :t AND c.constraint_type = 'U'
            GROUP BY c.constraint_name`,
          { o: meta.owner, t: tbl },
        );
        meta.unique_keys = (uk.rows ?? []).map((r) => r[1].split(","));
      } catch { /* leave empty */ }

      // 5) Foreign keys — child columns + referenced table.columns.
      try {
        const fk = await conn.execute<[string, string, string, string, string]>(
          `SELECT c.constraint_name,
                  LISTAGG(cc.column_name, ',') WITHIN GROUP (ORDER BY cc.position) AS child_cols,
                  rc.table_name  AS ref_table,
                  LISTAGG(rcc.column_name, ',') WITHIN GROUP (ORDER BY rcc.position) AS ref_cols,
                  c.r_constraint_name
             FROM all_constraints c
             JOIN all_cons_columns cc
               ON cc.constraint_name = c.constraint_name AND cc.owner = c.owner
             JOIN all_constraints rc
               ON rc.constraint_name = c.r_constraint_name AND rc.owner = c.r_owner
             JOIN all_cons_columns rcc
               ON rcc.constraint_name = rc.constraint_name AND rcc.owner = rc.owner
              AND rcc.position = cc.position
            WHERE c.owner = :o AND c.table_name = :t AND c.constraint_type = 'R'
            GROUP BY c.constraint_name, rc.table_name, c.r_constraint_name`,
          { o: meta.owner, t: tbl },
        );
        meta.foreign_keys = (fk.rows ?? []).map((r) => ({
          name: r[0],
          columns: r[1].split(","),
          references_table: r[2],
          references_columns: r[3].split(","),
        }));
      } catch { /* leave empty */ }

      // 6) Indexes with ordered column lists + uniqueness.
      try {
        const ix = await conn.execute<[string, string, string]>(
          `SELECT i.index_name, i.uniqueness,
                  LISTAGG(ic.column_name, ',')
                    WITHIN GROUP (ORDER BY ic.column_position) AS cols
             FROM all_indexes i
             JOIN all_ind_columns ic
               ON ic.index_name = i.index_name AND ic.index_owner = i.owner
            WHERE i.table_owner = :o AND i.table_name = :t
            GROUP BY i.index_name, i.uniqueness
            ORDER BY i.index_name`,
          { o: meta.owner, t: tbl },
        );
        meta.indexes = (ix.rows ?? []).map((r) => ({
          name: r[0],
          unique: r[1] === "UNIQUE",
          columns: (r[2] || "").split(","),
        }));
      } catch { /* leave empty */ }

      result.push(meta);
    }

    return NextResponse.json({ tables: result });
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
