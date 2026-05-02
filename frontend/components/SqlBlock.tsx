// Lightweight SQL highlighter — returns React nodes with class names matching globals.css
import * as React from "react";

const KEYWORDS = new Set([
  "SELECT","FROM","WHERE","AND","OR","NOT","IN","IS","NULL","AS","ON","JOIN","INNER","LEFT","RIGHT",
  "OUTER","FULL","CROSS","GROUP","BY","ORDER","HAVING","LIMIT","OFFSET","UNION","ALL","DISTINCT",
  "INSERT","INTO","VALUES","UPDATE","SET","DELETE","CREATE","TABLE","INDEX","VIEW","DROP","ALTER",
  "ADD","COLUMN","WITH","CASE","WHEN","THEN","ELSE","END","EXISTS","BETWEEN","LIKE","ASC","DESC",
  "PARTITION","OVER","ROWS","RANGE","FETCH","FIRST","NEXT","ONLY","TRUNCATE","BEGIN","COMMIT",
  "ROLLBACK","DECLARE","IF","FOR","LOOP","RETURN","CONNECT","START","SIBLINGS","PRIOR",
]);
const FUNCTIONS = new Set([
  "COUNT","SUM","AVG","MIN","MAX","COALESCE","NVL","UPPER","LOWER","TRIM","SUBSTR","SUBSTRING",
  "LENGTH","ROUND","CAST","TO_DATE","TO_CHAR","TO_NUMBER","SYSDATE","CURRENT_DATE","CURRENT_TIMESTAMP",
  "ROW_NUMBER","RANK","DENSE_RANK","LEAD","LAG","ROWNUM","DECODE","LISTAGG",
]);

export function highlightSql(sql: string): React.ReactNode[] {
  const tokens: React.ReactNode[] = [];
  // Split preserving delimiters using regex
  const re = /(--[^\n]*|\/\*[\s\S]*?\*\/|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z_0-9]*\b|\s+|[^\s\w])/g;
  let m: RegExpExecArray | null;
  let i = 0;
  let key = 0;
  while ((m = re.exec(sql)) !== null) {
    const t = m[0];
    if (t.startsWith("--") || t.startsWith("/*")) {
      tokens.push(<span key={key++} className="sql-com">{t}</span>);
    } else if (t.startsWith("'") || t.startsWith('"')) {
      tokens.push(<span key={key++} className="sql-str">{t}</span>);
    } else if (/^\d/.test(t)) {
      tokens.push(<span key={key++} className="sql-num">{t}</span>);
    } else if (/^[A-Za-z_]/.test(t)) {
      const up = t.toUpperCase();
      if (KEYWORDS.has(up)) tokens.push(<span key={key++} className="sql-kw">{t}</span>);
      else if (FUNCTIONS.has(up)) tokens.push(<span key={key++} className="sql-fn">{t}</span>);
      else tokens.push(<React.Fragment key={key++}>{t}</React.Fragment>);
    } else {
      tokens.push(<React.Fragment key={key++}>{t}</React.Fragment>);
    }
    i = m.index + t.length;
  }
  if (i < sql.length) tokens.push(<React.Fragment key={key++}>{sql.slice(i)}</React.Fragment>);
  return tokens;
}

export function SqlBlock({ sql, className = "" }: { sql: string; className?: string }) {
  return (
    <pre className={`font-mono-app text-[13px] leading-[1.65] whitespace-pre-wrap break-words ${className}`}>
      <code>{highlightSql(sql)}</code>
    </pre>
  );
}
