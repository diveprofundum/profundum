import Foundation
import GRDB

/// Main database access point for the divelog application.
public final class DivelogDatabase: Sendable {
    /// The underlying GRDB database queue.
    public let dbQueue: DatabaseQueue

    /// Creates a new database connection.
    /// - Parameter path: Path to the SQLite database file. Use `:memory:` for in-memory database.
    public init(path: String) throws {
        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("SQL: \($0)") }
        }
        #endif

        if path == ":memory:" {
            dbQueue = try DatabaseQueue(configuration: config)
        } else {
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        }

        try migrate()
    }

    /// Run database migrations.
    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // Migration 1: Initial schema
        migrator.registerMigration("001_init") { db in
            try db.execute(sql: """
                PRAGMA foreign_keys = ON;

                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY,
                    model TEXT NOT NULL,
                    serial_number TEXT NOT NULL,
                    firmware_version TEXT NOT NULL,
                    last_sync_unix INTEGER
                );

                CREATE TABLE IF NOT EXISTS sites (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    lat REAL,
                    lon REAL,
                    notes TEXT
                );

                CREATE TABLE IF NOT EXISTS site_tags (
                    site_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (site_id, tag),
                    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS buddies (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    contact TEXT,
                    notes TEXT
                );

                CREATE TABLE IF NOT EXISTS equipment (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    serial_number TEXT,
                    service_interval_days INTEGER,
                    notes TEXT
                );

                CREATE TABLE IF NOT EXISTS dives (
                    id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    start_time_unix INTEGER NOT NULL,
                    end_time_unix INTEGER NOT NULL,
                    max_depth_m REAL NOT NULL,
                    avg_depth_m REAL NOT NULL,
                    bottom_time_sec INTEGER NOT NULL,
                    is_ccr INTEGER NOT NULL,
                    deco_required INTEGER NOT NULL,
                    cns_percent REAL NOT NULL,
                    otu REAL NOT NULL,
                    o2_consumed_psi REAL,
                    o2_consumed_bar REAL,
                    o2_rate_cuft_min REAL,
                    o2_rate_l_min REAL,
                    o2_tank_factor REAL,
                    site_id TEXT,
                    FOREIGN KEY (device_id) REFERENCES devices(id),
                    FOREIGN KEY (site_id) REFERENCES sites(id)
                );

                CREATE TABLE IF NOT EXISTS dive_tags (
                    dive_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (dive_id, tag),
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS dive_buddies (
                    dive_id TEXT NOT NULL,
                    buddy_id TEXT NOT NULL,
                    PRIMARY KEY (dive_id, buddy_id),
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE,
                    FOREIGN KEY (buddy_id) REFERENCES buddies(id)
                );

                CREATE TABLE IF NOT EXISTS dive_equipment (
                    dive_id TEXT NOT NULL,
                    equipment_id TEXT NOT NULL,
                    PRIMARY KEY (dive_id, equipment_id),
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE,
                    FOREIGN KEY (equipment_id) REFERENCES equipment(id)
                );

                CREATE TABLE IF NOT EXISTS segments (
                    id TEXT PRIMARY KEY,
                    dive_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    start_t_sec INTEGER NOT NULL,
                    end_t_sec INTEGER NOT NULL,
                    notes TEXT,
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS segment_tags (
                    segment_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (segment_id, tag),
                    FOREIGN KEY (segment_id) REFERENCES segments(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS formulas (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    expression TEXT NOT NULL,
                    description TEXT
                );

                CREATE TABLE IF NOT EXISTS settings (
                    id TEXT PRIMARY KEY,
                    time_format TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS calculated_fields (
                    formula_id TEXT NOT NULL,
                    dive_id TEXT NOT NULL,
                    value REAL NOT NULL,
                    PRIMARY KEY (formula_id, dive_id),
                    FOREIGN KEY (formula_id) REFERENCES formulas(id) ON DELETE CASCADE,
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS samples (
                    dive_id TEXT NOT NULL,
                    t_sec INTEGER NOT NULL,
                    depth_m REAL NOT NULL,
                    temp_c REAL NOT NULL,
                    setpoint_ppo2 REAL,
                    ceiling_m REAL,
                    gf99 REAL,
                    PRIMARY KEY (dive_id, t_sec),
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE
                );

                -- Performance indices
                CREATE INDEX IF NOT EXISTS idx_dives_start_time ON dives(start_time_unix);
                CREATE INDEX IF NOT EXISTS idx_samples_dive ON samples(dive_id);
                CREATE INDEX IF NOT EXISTS idx_segments_dive ON segments(dive_id);
                CREATE INDEX IF NOT EXISTS idx_dives_depth ON dives(max_depth_m);
                CREATE INDEX IF NOT EXISTS idx_dives_ccr ON dives(is_ccr);
                CREATE INDEX IF NOT EXISTS idx_dives_deco ON dives(deco_required);
                CREATE INDEX IF NOT EXISTS idx_dive_tags_tag ON dive_tags(tag);
            """)
        }

        // Migration 2: Add soft-delete for devices
        // Devices can be archived rather than deleted, preserving dive history provenance.
        // Future consideration: dive merging from multiple devices.
        migrator.registerMigration("002_device_soft_delete") { db in
            try db.execute(sql: """
                ALTER TABLE devices ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1;
            """)
        }

        try migrator.migrate(dbQueue)
    }
}
