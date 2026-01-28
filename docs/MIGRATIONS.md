# SQLite Migrations

## Usage (Rust)
```rust
use rusqlite::Connection;
use divelog_core::migrations::ensure_schema;

let conn = Connection::open("divelog.db")?;
ensure_schema(&conn)?;
```

## Notes
- Migration files live in `core/migrations/` and are applied in version order.
- Add new migrations as `NNN_description.sql` and never edit old files.
