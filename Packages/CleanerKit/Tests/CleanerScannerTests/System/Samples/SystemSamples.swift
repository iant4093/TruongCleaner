/// Sample command output for the parser tests.
///
/// These are Swift string literals, not data files, because SwiftPM warns about
/// unhandled files in a test target and `Package.swift` is not ours to edit.
/// The `diskutil` and `simctl` samples are real output from a Mac running macOS 27,
/// trimmed, with UUIDs replaced by fakes and the user name by `example`.
/// The `tmutil` samples are written by hand from the documented format
/// (the capture Mac has no local snapshots).
enum SystemSamples {
    static let tmutilListEmpty = #"""
Snapshots for disk /:
"""#

    static let tmutilDatesEmpty = #"""
Snapshot dates for disk /:
"""#

    static let tmutilListFour = #"""
Snapshots for disk /:
com.apple.TimeMachine.2026-11-03-091500.local
com.apple.TimeMachine.2026-11-04-101500.local
com.apple.TimeMachine.2026-11-05-111500.local
com.example.backup-tool.snapshot-42
"""#

    static let tmutilDatesThree = #"""
Snapshot dates for disk /:
2026-11-03-091500
2026-11-04-101500
2026-11-05-111500
"""#

    static let diskutilAPFSList = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Containers</key>
	<array>
		<dict>
			<key>APFSContainerUUID</key>
			<string>00000000-0000-4000-8000-000000000001</string>
			<key>CapacityCeiling</key>
			<integer>524288000</integer>
			<key>CapacityFree</key>
			<integer>503402496</integer>
			<key>ContainerReference</key>
			<string>disk1</string>
			<key>DesignatedPhysicalStore</key>
			<string>disk0s1</string>
			<key>PhysicalStores</key>
			<array>
				<dict>
					<key>DeviceIdentifier</key>
					<string>disk0s1</string>
					<key>Size</key>
					<integer>524288000</integer>
				</dict>
			</array>
			<key>Volumes</key>
			<array>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000002</string>
					<key>CapacityInUse</key>
					<integer>6082560</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk1s1</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>iSCPreboot</string>
					<key>Roles</key>
					<array>
						<string>Preboot</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000003</string>
					<key>CapacityInUse</key>
					<integer>6311936</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk1s2</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>xART</string>
					<key>Roles</key>
					<array>
						<string>xART</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000004</string>
					<key>CapacityInUse</key>
					<integer>3514368</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk1s3</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Hardware</string>
					<key>Roles</key>
					<array>
						<string>Hardware</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000005</string>
					<key>CapacityInUse</key>
					<integer>20480</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk1s4</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Recovery</string>
					<key>Roles</key>
					<array>
						<string>Recovery</string>
					</array>
				</dict>
			</array>
		</dict>
		<dict>
			<key>APFSContainerUUID</key>
			<string>00000000-0000-4000-8000-000000000006</string>
			<key>CapacityCeiling</key>
			<integer>994662584320</integer>
			<key>CapacityFree</key>
			<integer>61922512896</integer>
			<key>ContainerReference</key>
			<string>disk3</string>
			<key>DesignatedPhysicalStore</key>
			<string>disk0s2</string>
			<key>PhysicalStores</key>
			<array>
				<dict>
					<key>DeviceIdentifier</key>
					<string>disk0s2</string>
					<key>Size</key>
					<integer>994662584320</integer>
				</dict>
			</array>
			<key>Volumes</key>
			<array>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000007</string>
					<key>CapacityInUse</key>
					<integer>904122363904</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk3s1</string>
					<key>Encryption</key>
					<true/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Macintosh HD - Data</string>
					<key>Roles</key>
					<array>
						<string>Data</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000008</string>
					<key>CapacityInUse</key>
					<integer>78344192</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk3s2</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Update</string>
					<key>Roles</key>
					<array>
						<string>Update</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000009</string>
					<key>CapacityInUse</key>
					<integer>13653516288</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk3s3</string>
					<key>Encryption</key>
					<true/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Macintosh HD</string>
					<key>Roles</key>
					<array>
						<string>System</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000010</string>
					<key>CapacityInUse</key>
					<integer>10994040832</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk3s4</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Preboot</string>
					<key>Roles</key>
					<array>
						<string>Preboot</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000011</string>
					<key>CapacityInUse</key>
					<integer>1537617920</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk3s5</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>Recovery</string>
					<key>Roles</key>
					<array>
						<string>Recovery</string>
					</array>
				</dict>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000012</string>
					<key>CapacityInUse</key>
					<integer>2147504128</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk3s6</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>VM</string>
					<key>Roles</key>
					<array>
						<string>VM</string>
					</array>
				</dict>
			</array>
		</dict>
		<dict>
			<key>APFSContainerUUID</key>
			<string>00000000-0000-4000-8000-000000000013</string>
			<key>CapacityCeiling</key>
			<integer>18559795200</integer>
			<key>CapacityFree</key>
			<integer>503599104</integer>
			<key>ContainerReference</key>
			<string>disk5</string>
			<key>DesignatedPhysicalStore</key>
			<string>disk4s1</string>
			<key>PhysicalStores</key>
			<array>
				<dict>
					<key>DeviceIdentifier</key>
					<string>disk4s1</string>
					<key>Size</key>
					<integer>18559795200</integer>
				</dict>
			</array>
			<key>Volumes</key>
			<array>
				<dict>
					<key>APFSVolumeUUID</key>
					<string>00000000-0000-4000-8000-000000000014</string>
					<key>CapacityInUse</key>
					<integer>18008752128</integer>
					<key>CapacityQuota</key>
					<integer>0</integer>
					<key>CapacityReserve</key>
					<integer>0</integer>
					<key>DeviceIdentifier</key>
					<string>disk5s1</string>
					<key>Encryption</key>
					<false/>
					<key>FileVault</key>
					<false/>
					<key>Locked</key>
					<false/>
					<key>Name</key>
					<string>iOS 27.0 Simulator</string>
					<key>Roles</key>
					<array/>
				</dict>
			</array>
		</dict>
	</array>
</dict>
</plist>
"""#

    static let diskutilInfoRoot = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>APFSContainerReference</key>
	<string>disk3</string>
	<key>APFSPhysicalStores</key>
	<array>
		<dict>
			<key>APFSPhysicalStore</key>
			<string>disk0s2</string>
		</dict>
	</array>
	<key>DeviceIdentifier</key>
	<string>disk3s3s1</string>
	<key>FilesystemType</key>
	<string>apfs</string>
	<key>ParentWholeDisk</key>
	<string>disk3</string>
	<key>VolumeName</key>
	<string>Macintosh HD</string>
</dict>
</plist>
"""#

    static let simctlDevices = #"""
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
      {
        "availabilityError": "runtime profile not found",
        "dataPath": "/Users/example/Library/Developer/CoreSimulator/Devices/00000000-0000-4000-8000-000000000099/data",
        "dataPathSize": 1048576,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
        "isAvailable": false,
        "name": "iPhone 15",
        "state": "Shutdown",
        "udid": "00000000-0000-4000-8000-000000000099"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      {
        "dataPath": "/Users/example/Library/Developer/CoreSimulator/Devices/00000000-0000-4000-8000-000000000015/data",
        "dataPathSize": 1366294528,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
        "isAvailable": true,
        "lastUsedAt": "2026-11-01T18:58:15Z",
        "logPath": "/Users/example/Library/Logs/CoreSimulator/00000000-0000-4000-8000-000000000015",
        "logPathSize": 208896,
        "name": "iPhone 18 Pro",
        "state": "Shutdown",
        "udid": "00000000-0000-4000-8000-000000000015"
      },
      {
        "dataPath": "/Users/example/Library/Developer/CoreSimulator/Devices/00000000-0000-4000-8000-000000000016/data",
        "dataPathSize": 822624256,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max",
        "isAvailable": true,
        "lastUsedAt": "2026-10-16T23:09:56Z",
        "logPath": "/Users/example/Library/Logs/CoreSimulator/00000000-0000-4000-8000-000000000016",
        "logPathSize": 225280,
        "name": "iPhone 18 Pro Max",
        "state": "Shutdown",
        "udid": "00000000-0000-4000-8000-000000000016"
      },
      {
        "dataPath": "/Users/example/Library/Developer/CoreSimulator/Devices/00000000-0000-4000-8000-000000000017/data",
        "dataPathSize": 668172288,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17e",
        "isAvailable": true,
        "lastUsedAt": "2026-10-16T23:09:56Z",
        "logPath": "/Users/example/Library/Logs/CoreSimulator/00000000-0000-4000-8000-000000000017",
        "logPathSize": 225280,
        "name": "iPhone 17e",
        "state": "Shutdown",
        "udid": "00000000-0000-4000-8000-000000000017"
      },
      {
        "dataPath": "/Users/example/Library/Developer/CoreSimulator/Devices/00000000-0000-4000-8000-000000000018/data",
        "dataPathSize": 16408576,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Air",
        "isAvailable": true,
        "logPath": "/Users/example/Library/Logs/CoreSimulator/00000000-0000-4000-8000-000000000018",
        "name": "iPhone Air",
        "state": "Shutdown",
        "udid": "00000000-0000-4000-8000-000000000018"
      }
    ]
  }
}
"""#

    static let simctlRuntimes = #"""
{
  "00000000-0000-4000-8000-000000000019": {
    "build": "24A434",
    "deletable": true,
    "identifier": "00000000-0000-4000-8000-000000000019",
    "kind": "Patchable Cryptex Disk Image",
    "lastUsedAt": "2026-10-31T20:32:52Z",
    "mountPath": "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1.434.0.UupB6n",
    "parentMountPath": "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/0000000000000000000000000000000000000000.asset/AssetData",
    "path": "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/0000000000000000000000000000000000000000.asset/AssetData",
    "platformIdentifier": "com.apple.platform.iphonesimulator",
    "runtimeBundlePath": "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1.434.0.UupB6n/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime",
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    "signatureState": "Unknown",
    "sizeBytes": 8067000161,
    "state": "Ready",
    "supportedArchitectures": [
      "arm64"
    ],
    "version": "27.0"
  },
  "00000000-0000-4000-8000-000000000098": {
    "deletable": false,
    "identifier": "00000000-0000-4000-8000-000000000098",
    "kind": "Disk Image",
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-12-0",
    "state": "Ready",
    "version": "12.0"
  }
}
"""#

    /// Not a `tmutil` listing: no header line, control characters.
    static let tmutilGarbage = "tmutil: this is not the output you are looking for\n\u{01}\u{02} garbage\n"
}
