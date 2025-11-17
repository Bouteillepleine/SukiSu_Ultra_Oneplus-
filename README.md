# OnePlus Kernels with SukiSU Ultra and SUSFS

<div align="center">


</div>

---

<a name="english"></a>

## English

This repository provides GitHub Actions workflows to automatically build flashable AnyKernel3 ZIPs for multiple OnePlus devices with integrated SukiSU Ultra and SUSFS support.

### 🌟 Features

- **SukiSU Ultra** - Advanced kernel-level root solution
- **SUSFS (Super User File System)** - Enhanced file system security and isolation
- **Baseband Guard LSM** (Optional) - Additional security layer
- **WireGuard** - Modern VPN protocol built into the kernel
- **Magic Mount** - Advanced mounting capabilities
- **TMPFS_XATTR (Mountify)** - Extended attribute support for tmpfs
- **BBR & ECN** - Advanced TCP congestion control and network optimizations
- **sched_ext** - Extensible scheduler framework (6.6 kernels)
- **hmbird conversion** - Optimized for certain 6.6 kernel cases

### 📱 Supported Devices: Oneplus devices

🚀 Installation
Download the latest kernel ZIP for your device from Releases
Flash the AnyKernel3 ZIP with Kernel Flasher / SukiSU Manager to enable KPM
Reboot and enjoy!
⚠️ Warning: Always backup your data before flashing custom kernels. 

🔧 Build Artifacts
Each build produces:

Flashable AnyKernel3 ZIP - Ready to flash kernel package
Build metadata - Detailed build information and logs
🛠️ Building Locally
To trigger a build for a specific device, use the GitHub Actions workflow or clone and build manually:

# Clone the repository
git clone https://github.com/Bouteillepleine/SukiSu_Ultra_Oneplus-.git
cd Oneplus-Kernels-SukiSu

# Follow the workflow scripts for your target device
📋 Requirements
Unlocked bootloader
Compatible OnePlus device from the supported list
Basic knowledge of flashing custom kernels
🤝 Acknowledgments
This project wouldn't be possible without:

KernelSU-Next & SukiSU Ultra & Wild+
susfs4ksu by simonpunk
AnyKernel3 by osm0sis and contributors
OnePlusOSS - Official OnePlus kernel sources
Community contributors - For testing, feedback, and improvements

⚠️ Disclaimer
Always ensure you have a backup and know how to restore your device


