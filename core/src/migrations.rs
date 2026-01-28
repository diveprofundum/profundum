use std::fs;
use std::path::Path;

pub const MIGRATIONS_DIR: &str = "core/migrations";

pub fn ensure_schema(conn: &rusqlite::Connection) -> Result<(), rusqlite::Error> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)",
        [],
    )?;
    let current: i64 = conn.query_row(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
        [],
        |row| row.get(0),
    )?;

    let mut entries: Vec<_> = fs::read_dir(Path::new(MIGRATIONS_DIR))
        .map_err(|_| rusqlite::Error::InvalidPath(Path::new(MIGRATIONS_DIR).to_path_buf()))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|s| s == "sql").unwrap_or(false))
        .collect();
    entries.sort_by_key(|e| e.path());

    for entry in entries {
        let path = entry.path();
        let file_name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("0");
        let version: i64 = file_name
            .split('_')
            .next()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        if version <= current {
            continue;
        }
        let sql = fs::read_to_string(&path)
            .map_err(|_| rusqlite::Error::InvalidPath(path.clone()))?;
        let tx = conn.transaction()?;
        tx.execute_batch(&sql)?;
        tx.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?, strftime('%s','now'))",
            [version],
        )?;
        tx.commit()?;
    }

    Ok(())
}
