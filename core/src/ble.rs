#[derive(Clone, Debug)]
pub struct BleDeviceInfo {
    pub id: String,
    pub name: String,
    pub rssi: i16,
}

#[derive(Clone, Debug)]
pub struct BleLogHeader {
    pub id: String,
    pub start_time_unix: i64,
    pub duration_sec: i32,
    pub max_depth_m: f32,
}

#[derive(Clone, Debug)]
pub struct BleChunk {
    pub offset: u32,
    pub data: Vec<u8>,
    pub crc: Option<u32>,
}

#[derive(Clone, Debug)]
pub enum BleError {
    PermissionDenied,
    BluetoothOff,
    DeviceNotFound,
    ConnectionFailed,
    GattError,
    ChecksumMismatch,
    Timeout,
    Cancelled,
    Unknown,
}

pub trait BleAdapter {
    type Session;

    fn scan(&mut self, timeout_ms: u32) -> Result<Vec<BleDeviceInfo>, BleError>;
    fn connect(&mut self, device_id: &str) -> Result<Self::Session, BleError>;
    fn disconnect(&mut self, session: &mut Self::Session) -> Result<(), BleError>;

    fn list_logs(&mut self, session: &mut Self::Session) -> Result<Vec<BleLogHeader>, BleError>;
    fn download_log(
        &mut self,
        session: &mut Self::Session,
        log_id: &str,
        resume_offset: Option<u32>,
    ) -> Result<Vec<BleChunk>, BleError>;
    fn cancel(&mut self, session: &mut Self::Session) -> Result<(), BleError>;
}
