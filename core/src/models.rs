#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DeviceId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DiveId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SiteId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct BuddyId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EquipmentId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SegmentId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FormulaId(pub String);

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SettingsId(pub String);

#[derive(Clone, Debug)]
pub enum TimeFormat {
    HhMmSs,
    MmSs,
}

#[derive(Clone, Debug)]
pub struct Device {
    pub id: DeviceId,
    pub model: String,
    pub serial_number: String,
    pub firmware_version: String,
    pub last_sync_unix: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct Site {
    pub id: SiteId,
    pub name: String,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub notes: Option<String>,
    pub tags: Vec<Tag>,
}

#[derive(Clone, Debug)]
pub struct Buddy {
    pub id: BuddyId,
    pub display_name: String,
    pub contact: Option<String>,
    pub notes: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Equipment {
    pub id: EquipmentId,
    pub name: String,
    pub kind: String,
    pub serial_number: Option<String>,
    pub service_interval_days: Option<i32>,
    pub notes: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Dive {
    pub id: DiveId,
    pub device_id: DeviceId,
    pub start_time_unix: i64,
    pub end_time_unix: i64,
    pub max_depth_m: f32,
    pub avg_depth_m: f32,
    pub bottom_time_sec: i32,
    pub is_ccr: bool,
    pub deco_required: bool,
    pub cns_percent: f32,
    pub otu: f32,
    pub o2_consumed_psi: Option<f32>,
    pub o2_consumed_bar: Option<f32>,
    pub o2_rate_cuft_min: Option<f32>,
    pub o2_rate_l_min: Option<f32>,
    pub o2_tank_factor: Option<f32>,
    pub tags: Vec<Tag>,
    pub site_id: Option<SiteId>,
    pub buddy_ids: Vec<BuddyId>,
    pub equipment_ids: Vec<EquipmentId>,
    pub segments: Vec<Segment>,
}

#[derive(Clone, Debug)]
pub struct Segment {
    pub id: SegmentId,
    pub dive_id: DiveId,
    pub name: String,
    pub start_t_sec: i32,
    pub end_t_sec: i32,
    pub tags: Vec<Tag>,
    pub notes: Option<String>,
}

#[derive(Clone, Debug)]
pub struct DiveSample {
    pub dive_id: DiveId,
    pub t_sec: i32,
    pub depth_m: f32,
    pub temp_c: f32,
    pub setpoint_ppo2: Option<f32>,
    pub ceiling_m: Option<f32>,
    pub gf99: Option<f32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Tag(pub String);

#[derive(Clone, Debug)]
pub struct Formula {
    pub id: FormulaId,
    pub name: String,
    pub expression: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub id: SettingsId,
    pub time_format: TimeFormat,
}

#[derive(Clone, Debug)]
pub struct CalculatedField {
    pub formula_id: FormulaId,
    pub dive_id: DiveId,
    pub value: f64,
}
