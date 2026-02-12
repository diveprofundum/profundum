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
        let isMemory = path == ":memory:"
        config.prepareDatabase { db in
            #if DEBUG
            db.trace { print("SQL: \($0)") }
            #endif
            if !isMemory {
                try db.execute(sql: """
                    PRAGMA journal_mode = WAL;
                    PRAGMA synchronous = NORMAL;
                    PRAGMA mmap_size = 67108864;
                """)
            }
        }

        if isMemory {
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

        // Migration 3: Add certification_level to buddies (now called teammates in UI)
        migrator.registerMigration("003_teammate_certification") { db in
            try db.execute(sql: """
                ALTER TABLE buddies ADD COLUMN certification_level TEXT;
            """)
        }

        // Migration 4: Add dive computer import columns
        migrator.registerMigration("004_dive_computer_columns") { db in
            try db.execute(sql: """
                ALTER TABLE devices ADD COLUMN vendor_id INTEGER;
                ALTER TABLE devices ADD COLUMN product_id INTEGER;
                ALTER TABLE devices ADD COLUMN ble_uuid TEXT;
                ALTER TABLE dives ADD COLUMN computer_dive_number INTEGER;
                ALTER TABLE dives ADD COLUMN fingerprint BLOB;
                CREATE INDEX IF NOT EXISTS idx_dives_fingerprint ON dives(fingerprint);
            """)
        }

        // Migration 5: Add last_service_date to equipment
        migrator.registerMigration("005_equipment_service_date") { db in
            try db.execute(sql: """
                ALTER TABLE equipment ADD COLUMN last_service_date INTEGER;
            """)
        }

        // Migration 6: Add unit preferences and appearance mode to settings
        migrator.registerMigration("006_unit_preferences") { db in
            try db.execute(sql: """
                ALTER TABLE settings ADD COLUMN depth_unit TEXT;
                ALTER TABLE settings ADD COLUMN temperature_unit TEXT;
                ALTER TABLE settings ADD COLUMN pressure_unit TEXT;
                ALTER TABLE settings ADD COLUMN appearance_mode TEXT;
            """)
        }

        // Migration 7: Expanded CCR data, multi-device samples, gas mixes, source fingerprints
        migrator.registerMigration("007_expanded_ccr_data") { db in
            // 7a. New columns on dives
            try db.execute(sql: """
                ALTER TABLE dives ADD COLUMN notes TEXT;
                ALTER TABLE dives ADD COLUMN min_temp_c REAL;
                ALTER TABLE dives ADD COLUMN max_temp_c REAL;
                ALTER TABLE dives ADD COLUMN avg_temp_c REAL;
                ALTER TABLE dives ADD COLUMN end_gf99 REAL;
                ALTER TABLE dives ADD COLUMN gf_low INTEGER;
                ALTER TABLE dives ADD COLUMN gf_high INTEGER;
                ALTER TABLE dives ADD COLUMN deco_model TEXT;
                ALTER TABLE dives ADD COLUMN salinity TEXT;
                ALTER TABLE dives ADD COLUMN surface_pressure_bar REAL;
                ALTER TABLE dives ADD COLUMN lat REAL;
                ALTER TABLE dives ADD COLUMN lon REAL;
                ALTER TABLE dives ADD COLUMN group_id TEXT;
                ALTER TABLE dives ADD COLUMN environment TEXT;
                ALTER TABLE dives ADD COLUMN visibility TEXT;
                ALTER TABLE dives ADD COLUMN weather TEXT;
            """)

            // 7b. Rebuild samples table with id PK and new columns
            try db.execute(sql: """
                CREATE TABLE samples_new (
                    id TEXT PRIMARY KEY,
                    dive_id TEXT NOT NULL,
                    device_id TEXT,
                    t_sec INTEGER NOT NULL,
                    depth_m REAL NOT NULL,
                    temp_c REAL NOT NULL,
                    setpoint_ppo2 REAL,
                    ceiling_m REAL,
                    gf99 REAL,
                    ppo2_1 REAL,
                    ppo2_2 REAL,
                    ppo2_3 REAL,
                    cns REAL,
                    tank_pressure_1_bar REAL,
                    tank_pressure_2_bar REAL,
                    tts_sec INTEGER,
                    ndl_sec INTEGER,
                    deco_stop_depth_m REAL,
                    rbt_sec INTEGER,
                    gasmix_index INTEGER,
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE,
                    FOREIGN KEY (device_id) REFERENCES devices(id)
                );
                INSERT INTO samples_new (id, dive_id, t_sec, depth_m, temp_c, setpoint_ppo2, ceiling_m, gf99)
                    SELECT lower(hex(randomblob(16))), dive_id, t_sec, depth_m, temp_c, setpoint_ppo2, ceiling_m, gf99
                    FROM samples;
                DROP TABLE samples;
                ALTER TABLE samples_new RENAME TO samples;
                CREATE INDEX idx_samples_dive ON samples(dive_id);
                CREATE INDEX idx_samples_device ON samples(device_id);
            """)

            // 7c. Gas mixes table
            try db.execute(sql: """
                CREATE TABLE gas_mixes (
                    id TEXT PRIMARY KEY,
                    dive_id TEXT NOT NULL,
                    mix_index INTEGER NOT NULL,
                    o2_fraction REAL NOT NULL,
                    he_fraction REAL NOT NULL,
                    usage TEXT,
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE
                );
                CREATE INDEX idx_gas_mixes_dive ON gas_mixes(dive_id);
            """)

            // 7d. Dive source fingerprints table
            try db.execute(sql: """
                CREATE TABLE dive_source_fingerprints (
                    id TEXT PRIMARY KEY,
                    dive_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    fingerprint BLOB NOT NULL,
                    source_type TEXT NOT NULL DEFAULT 'shearwater_cloud',
                    FOREIGN KEY (dive_id) REFERENCES dives(id) ON DELETE CASCADE,
                    FOREIGN KEY (device_id) REFERENCES devices(id)
                );
                CREATE INDEX idx_dsf_fingerprint ON dive_source_fingerprints(fingerprint);
                CREATE INDEX idx_dsf_dive ON dive_source_fingerprints(dive_id);
            """)

            // Migrate existing fingerprints to new table
            try db.execute(sql: """
                INSERT INTO dive_source_fingerprints (id, dive_id, device_id, fingerprint, source_type)
                    SELECT lower(hex(randomblob(16))), id, device_id, fingerprint, 'shearwater_cloud'
                    FROM dives WHERE fingerprint IS NOT NULL;
            """)
        }

        // Migration 8: Additional indices for common FK lookups
        migrator.registerMigration("008_additional_indices") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_dives_site_id ON dives(site_id);
                CREATE INDEX IF NOT EXISTS idx_dives_device_id ON dives(device_id);
            """)
        }

        // Migration 9: Backfill breathing-system (oc, ccr) and activity (rec, deco) tags on existing dives
        migrator.registerMigration("009_backfill_type_tags") { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'ccr' FROM dives WHERE is_ccr = 1;

                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'oc' FROM dives WHERE is_ccr = 0;

                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'deco' FROM dives WHERE deco_required = 1;

                INSERT OR IGNORE INTO dive_tags (dive_id, tag)
                SELECT id, 'rec' FROM dives WHERE is_ccr = 0 AND deco_required = 0;
            """)
        }

        migrator.registerMigration("010_add_clock_format") { db in
            if try !db.columns(in: "settings").contains(where: { $0.name == "clock_format" }) {
                try db.execute(sql: """
                    ALTER TABLE settings ADD COLUMN clock_format TEXT DEFAULT 'system';
                """)
            }
        }

        migrator.registerMigration("011_add_max_ceiling") { db in
            try db.execute(sql: """
                ALTER TABLE dives ADD COLUMN max_ceiling_m REAL;

                UPDATE dives SET max_ceiling_m = (
                    SELECT MAX(ceiling_m) FROM samples WHERE samples.dive_id = dives.id
                );
            """)
        }

        try migrator.migrate(dbQueue)
    }
}
