use crate::ble::{BleAdapter, BleChunk, BleDeviceInfo, BleError, BleLogHeader};

#[derive(Clone, Debug, Default)]
pub struct MockSession {
    pub connected_device_id: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct MockBleAdapter {
    pub devices: Vec<BleDeviceInfo>,
    pub logs: Vec<BleLogHeader>,
    pub chunks: Vec<BleChunk>,
}

impl MockBleAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_sample_data() -> Self {
        Self {
            devices: vec![BleDeviceInfo {
                id: "mock-device-1".to_string(),
                name: "Perdix AI".to_string(),
                rssi: -61,
            }],
            logs: vec![BleLogHeader {
                id: "log-001".to_string(),
                start_time_unix: 1_705_000_000,
                duration_sec: 5_040,
                max_depth_m: 62.0,
            }],
            chunks: vec![BleChunk {
                offset: 0,
                data: vec![0x01, 0x02, 0x03],
                crc: Some(0xDEADBEEF),
            }],
        }
    }
}

impl BleAdapter for MockBleAdapter {
    type Session = MockSession;

    fn scan(&mut self, _timeout_ms: u32) -> Result<Vec<BleDeviceInfo>, BleError> {
        Ok(self.devices.clone())
    }

    fn connect(&mut self, device_id: &str) -> Result<Self::Session, BleError> {
        let exists = self.devices.iter().any(|d| d.id == device_id);
        if !exists {
            return Err(BleError::DeviceNotFound);
        }
        Ok(MockSession {
            connected_device_id: Some(device_id.to_string()),
        })
    }

    fn disconnect(&mut self, session: &mut Self::Session) -> Result<(), BleError> {
        session.connected_device_id = None;
        Ok(())
    }

    fn list_logs(&mut self, session: &mut Self::Session) -> Result<Vec<BleLogHeader>, BleError> {
        if session.connected_device_id.is_none() {
            return Err(BleError::ConnectionFailed);
        }
        Ok(self.logs.clone())
    }

    fn download_log(
        &mut self,
        session: &mut Self::Session,
        _log_id: &str,
        _resume_offset: Option<u32>,
    ) -> Result<Vec<BleChunk>, BleError> {
        if session.connected_device_id.is_none() {
            return Err(BleError::ConnectionFailed);
        }
        Ok(self.chunks.clone())
    }

    fn cancel(&mut self, _session: &mut Self::Session) -> Result<(), BleError> {
        Ok(())
    }
}
