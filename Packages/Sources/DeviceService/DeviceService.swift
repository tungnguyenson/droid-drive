// DeviceService: what the app and the File Provider extension share above the
// transports (plan P1-11, phase 4).
//
// App side:       DeviceSource → DeviceRegistry (TransportProvider) → DeviceHost (XPC)
// Extension side: DeviceLinkListener → HostLink → RemoteDeviceTransport (DeviceTransport)
// Also:           TransferMonitor + TransferLog (FR-17), RefreshSchedule, StoragePlan,
//                 KnownDevices.
