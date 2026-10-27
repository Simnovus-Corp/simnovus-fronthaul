# O-RAN 7.2: 1 cell, 100 MHz: UE simulator + OCUDU gNB configs

A matching pair of configs for one n78 100 MHz cell (30 kHz, TDD 7D-S-2U, 1T1R) over O-RAN 7.2.

| File | Where |
|---|---|
| `gnb-ocudu-1cell-100MHz-1x1.yml` | OCUDU gNB (O-DU) |
| `ue-1cell-100MHz-1x1.cfg` | Simnovus UE simulator |
| `open5gs/` | 5G core (Open5GS): AMF, SMF, UPF and NRF configs, see [open5gs/README.md](open5gs/README.md) |

Validated on 2026-10-26: UE simulator in a VM (12 vCPUs, one SR-IOV VF) against OCUDU, 433 Mb/s DL and 118 Mb/s UL, BLER 0%.

## Before you start

1. **PTP** on the host and in the VM:
   `curl -fsSL https://github.com/Simnovus-Corp/simnovus-ptp/releases/latest/download/simnovus-ptp.sh | sudo bash`
2. **Fronthaul VF** on the host (it prints the VF MAC to enter on the gNB):
   `curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-fronthaul.sh | sudo bash -s -- --if <fronthaul port> --vlan <VLAN> --vm <VM name>`
   then inside the VM, with no options:
   `curl -fsSL https://github.com/Simnovus-Corp/simnovus-fronthaul/releases/latest/download/simnovus-fronthaul.sh | sudo bash`
3. **Core:** set up Open5GS with the files in `open5gs/` and add the UE's IMSI, K and OPc (PLMN 00101, DNN `internet`). With the core on the gNB host, the gNB's AMF address is 127.0.0.5 and its N2/N3 bind addresses are 127.0.0.1.

Then replace every `<...>` placeholder in both files (marked CHANGE).

## What must match

| | gNB (`.yml`) | UE simulator (`.cfg`) |
|---|---|---|
| Fronthaul MACs | `du_mac_addr` | `remote_addr` |
| | `ru_mac_addr` | the VF's MAC (set on the host) |
| VLAN | `vlan_tag_cp` / `vlan_tag_up` | set on the VF by the host; `bind_interface` is the plain VF |
| Band / ARFCN / bandwidth / SCS | 78 / 650000 / 100 / 30 | same |
| Antennas | `nof_antennas_dl/ul` 1 | `n_antenna_dl/ul` 1 |
| eAxC | `dl_port_id` / `ul_port_id` 0, `prach_port_id` 4 | `rtc_id` 0, `port_mapping_prach` [4] |
| Compression | BFP 9 bits | `ud_comp_hdr` 0x91 |
| MTU | 9000 | `max_pdu_size` 8960 |
| PLMN / TAC | 00101 / 1 | the SIM's IMSI |

## Using it with Simnovator

In the test case (UE simulation), set Radio Type **O-RAN 7.2** with the same values: Bind Interface = the VF interface, Destination MAC = `du_mac_addr`, eAxC DL 0 / UL 0 / PRACH 4, compression BFP 9, MTU 9000, TAI offset 37, lteue cores 1-11, DL 2-3, UL 4.

## Run by hand (without Simnovator)

On the UE simulator:
```
sudo systemctl stop lte
cd /root/ue && sudo ./lteue /path/to/ue-1cell-100MHz-1x1.cfg
```
Start the gNB first. `t s72` in the console shows the fronthaul counters: late, early and lost should stay at 0.

## Other antenna setups

- **2x2:** gNB `nof_antennas_dl/ul: 2`, `dl_port_id/ul_port_id: [0, 1]`, `prach_port_id: [4, 5]`; UE `n_antenna_dl/ul: 2`, `port_mapping_prach: [4, 5]`. Validated at 831 Mb/s DL in a VM.
- **4x4:** 4 antennas and ports 0-3 / PRACH 4-7. Plan about 10 cores per 100 MHz cell on the UE side.
