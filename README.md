# niosx-installer
Consolidated NIOS-X installation script

## Purpose:
Determine and optionally execute the appropriate host-preparation and NIOS-X installation commands 
for a bare-metal Linux server, based on the Infoblox "NIOS-X Bare-Metal" deployment guide.  This
script will detect and ensure support OSes (currently RHEL up-to 8.9, 9.6 and Ubuntu 22.04, 24.04),
perform various validations before making any changes, and default to a dry-run/plan mode.

## Notes:
  - This script does NOT download the Infoblox installer automatically, but can do so with the
    flag --download.  The Infoblox documentation requires downloading the NIOS-X install script
    from the Infoblox Portal first. Pass that local file path with --install-script during the
    install phase.
  - Review the generated plan before using --mode execute in production.
  - Some network changes can interrupt remote sessions, so it is recommended to only use the
    --restart-network flag when logged in from the console.

## Usage:
```
$SCRIPT_NAME [options]

Options:
  --mode plan|execute             Default: plan
  --phase prep|install|all|reconfigure-network
                                  Default: all
  --join-token TOKEN              Required for install phase
  --install-script PATH           Path to downloaded Infoblox NIOS-X install script
  --proxy URL                     Proxy for NIOS-X installer, e.g. http://proxy:8080
  --cluster-cidr CIDR             Optional custom K3s cluster CIDR
  --service-cidr CIDR             Optional custom K3s service CIDR
  --portal-iface IFACE            On RHEL 9, interface used to reach Infoblox Portal
  --non-portal-ifaces LIST        Comma-separated interfaces that must not install a default route
  --dns-resolver IP               Ubuntu resolver to write to /etc/resolv.conf (default: 8.8.8.8)
  --restart-network		            Restart the network after making changes (console only recommended)
  --allow-reboot                  Permit reboot during execute/prep phase
  --download                      Download the official NIOS-X installer from Infoblox
  --force                         Continue despite non-fatal warnings where possible
  -h, --help                      Show this help
```

### Recommended workflow:
  1. Run in plan mode and review the generated commands.
  2. Run execute/prep.
  3. Reboot if indicated by the script or guide.
  4. Run execute/install.

## Examples:
```
1) Review all prep + install commands for this host
   ./niosx_prepare_and_install.sh \
     --phase all \
     --join-token YOUR_JOIN_TOKEN \
     --install-script /root/niosx_installer_v2.2.2.sh

2) Execute only the host preparation phase and download the Infoblox installer
   sudo ./niosx_prepare_and_install.sh --mode execute --phase prep --download

3) After reboot, execute the install phase with custom K3s CIDRs
   sudo ./niosx_prepare_and_install.sh \
     --mode execute \
     --phase install \
     --join-token YOUR_JOIN_TOKEN \
     --install-script /root/niosx_installer_v2.2.2.sh \
     --cluster-cidr 10.42.0.0/16 \
     --service-cidr 10.43.0.0/16

4) Reconfigure networking after host/DNS changes
   sudo ./niosx_prepare_and_install.sh \
     --mode execute \
     --phase reconfigure-network \
     --install-script /root/niosx_installer_v2.2.2.sh
```
