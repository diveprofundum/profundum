use crate::models::{
    Buddy, BuddyId, CalculatedField, Dive, DiveId, DiveSample, Device, DeviceId, Equipment,
    EquipmentId, Formula, FormulaId, Segment, SegmentId, Settings, SettingsId, Site, SiteId,
};

#[derive(Clone, Debug, Default)]
pub struct DiveQuery {
    pub start_time_min: Option<i64>,
    pub start_time_max: Option<i64>,
    pub min_depth_m: Option<f32>,
    pub max_depth_m: Option<f32>,
    pub is_ccr: Option<bool>,
    pub deco_required: Option<bool>,
    pub tag_any: Vec<String>,
}

pub trait Storage {
    fn upsert_device(&mut self, device: Device) -> Result<(), String>;
    fn list_devices(&self) -> Result<Vec<Device>, String>;

    fn upsert_site(&mut self, site: Site) -> Result<(), String>;
    fn list_sites(&self) -> Result<Vec<Site>, String>;

    fn upsert_buddy(&mut self, buddy: Buddy) -> Result<(), String>;
    fn list_buddies(&self) -> Result<Vec<Buddy>, String>;

    fn upsert_equipment(&mut self, equipment: Equipment) -> Result<(), String>;
    fn list_equipment(&self) -> Result<Vec<Equipment>, String>;

    fn upsert_dive(&mut self, dive: Dive) -> Result<(), String>;
    fn list_dives(&self, query: DiveQuery) -> Result<Vec<Dive>, String>;
    fn load_dive(&self, id: &DiveId) -> Result<Option<Dive>, String>;

    fn insert_samples(&mut self, samples: Vec<DiveSample>) -> Result<(), String>;
    fn load_samples(&self, id: &DiveId) -> Result<Vec<DiveSample>, String>;

    fn upsert_segment(&mut self, segment: Segment) -> Result<(), String>;
    fn list_segments(&self, dive_id: &DiveId) -> Result<Vec<Segment>, String>;

    fn upsert_formula(&mut self, formula: Formula) -> Result<(), String>;
    fn list_formulas(&self) -> Result<Vec<Formula>, String>;
    fn upsert_calculated_field(&mut self, field: CalculatedField) -> Result<(), String>;
    fn list_calculated_fields(&self, dive_id: &DiveId) -> Result<Vec<CalculatedField>, String>;

    fn upsert_settings(&mut self, settings: Settings) -> Result<(), String>;
    fn load_settings(&self, id: &SettingsId) -> Result<Option<Settings>, String>;
}

#[derive(Debug)]
pub struct StorageNotConfigured;

impl std::fmt::Display for StorageNotConfigured {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "storage not configured")
    }
}

impl std::error::Error for StorageNotConfigured {}
