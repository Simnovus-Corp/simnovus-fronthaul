# 5G core (Open5GS) for the 1-cell example

Validated with Open5GS 2.8.0 on the same host as the OCUDU gNB. Only these four files differ from the Open5GS package defaults:

| File | What is set |
|---|---|
| `amf.yaml` | PLMN 001/01, TAC 1, slice SST 1, N2 on 127.0.0.5 |
| `smf.yaml` | one DNN `internet`, UE addresses 10.45.0.0/16 |
| `upf.yaml` | N3 on 127.0.0.7, UE addresses 10.45.0.0/16 |
| `nrf.yaml` | PLMN 001/01 |

## Install

```
sudo add-apt-repository ppa:open5gs/latest
sudo apt-get install -y open5gs
sudo cp amf.yaml smf.yaml upf.yaml nrf.yaml /etc/open5gs/
sudo systemctl restart open5gs-nrfd open5gs-amfd open5gs-smfd open5gs-upfd
```

## Add the UE's SIM

Same IMSI, K and OPc as in the UE simulator's `ue.cfg`:

```
curl -fsSLO https://raw.githubusercontent.com/open5gs/open5gs/v2.8.0/misc/db/open5gs-dbctl
sudo bash open5gs-dbctl add <IMSI> <K> <OPC>
```

Or use the Open5GS WebUI.

## gNB addresses

| gNB placeholder | Core on the same host | Core on another machine |
|---|---|---|
| `<AMF_N2_IP>` | 127.0.0.5 | the core's IP (also set it in `amf.yaml` ngap) |
| `<GNB_N2_IP>` | 127.0.0.1 | the gNB host's IP |
| `<GNB_N3_IP>` | 127.0.0.1 | the gNB host's IP (and the core's IP in `upf.yaml` gtpu) |

## Traffic

The UEs get addresses in 10.45.0.0/16 behind the UPF. For throughput tests from the Simnovator app server, route that range to the core host:

```
sudo ip route add 10.45.0.0/16 via <core host IP>
```

On the core host, allow forwarding: `sudo sysctl -w net.ipv4.ip_forward=1`.
