# simnovus-fronthaul

Sets up the O-RAN 7.2 fronthaul interfaces for the Simnovus UE simulator: one SR-IOV VF per cell on the host's fronthaul port, with a fixed MAC and the fronthaul VLAN, kept across reboots and optionally given to a VM. Inside the VM it sets up the interfaces it received.

The NIC adds and removes the VLAN tag, so no VLAN interface is needed in the VM or in the test case.

## On the host

You need the name of the fronthaul port (the physical NIC port cabled to the O-DU or fronthaul switch) and the VLAN your O-DU uses.

```
curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-fronthaul.sh \
  | sudo bash -s -- --if <fronthaul port> --vlan <VLAN> --vm <VM name>
```

- Leave out `--vm` when the UE simulator runs directly on the host.
- Two cells: `--vlan 2,3` (or `--vlan 2 --cells 2` for the same VLAN).
- `--check` shows what it would do and changes nothing.

At the end it prints the RU MAC and VLAN for each cell: enter them on the O-DU. If the VM is running, shut it down and start it again so it gets the VF.

## Inside the VM

```
curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-fronthaul.sh | sudo bash
```

No input: it finds the VF(s) the host set up, sets MTU 9000, larger rings and no interrupt coalescing, keeps NetworkManager away from them, and repeats this at every boot. It prints the interface to use as **Bind Interface** in the test case.

## What it does on the host

- Checks the port: SR-IOV capable, not the management port, IOMMU on (for VMs).
- Creates the VFs if the port has none. If the port already has VFs, it uses them and won't recreate them; it refuses a VF that a running VM already uses.
- Per VF: MAC (generated from the port's MAC unless you give `--mac`), VLAN, `spoofchk off`, `trust on`. Port MTU 9000.
- Boot service `simnovus-fronthaul@<port>` repeats this at every boot, before PTP and the VMs start.
- `--vm`: adds the VF to the VM's configuration (`hostdev`, managed).

Undo: `--remove` (host: `--if <port> --remove`).

## Example configs

[`examples/oran72-1cell-100MHz`](examples/oran72-1cell-100MHz): a matching OCUDU gNB config and UE simulator config for one n78 100 MHz cell over O-RAN 7.2, with a table of the values that must match on both sides.

## Requirements

- Linux with systemd; Ubuntu 22.04/24.04 tested.
- An SR-IOV NIC (tested: Intel X710/XXV710/E810), SR-IOV and VT-d on in the BIOS, `intel_iommu=on iommu=pt` on the kernel command line for VMs.
- libvirt for `--vm`.
- PTP: use [simnovus-ptp](https://github.com/Simnovus-Corp/simnovus-ptp) on the host and in the VM.
