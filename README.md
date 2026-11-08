# ping and traceroute: field notes

Hands-on notes from measuring my own home network (a 5G router with a mesh extender, in South Africa) with nothing but `ping`, `tracert` and a small script. Every number below came from a real run. The raw output is in [`outputs/`](outputs/).

Part of my networking labs: **ping and traceroute** · [nmap](https://github.com/yaseenselemane/nmap-field-notes) · [WiFi survey](https://github.com/yaseenselemane/wifi-survey) · [Wireshark](https://github.com/yaseenselemane/wireshark-packet-lab) · [Packet Tracer](https://github.com/yaseenselemane/cisco-packet-tracer-labs) · [CCTV network](https://github.com/yaseenselemane/cctv-network-lab) · [subnet calculator](https://github.com/yaseenselemane/subnet-calculator) · [vantage](https://github.com/yaseenselemane/vantage)

---

## The troubleshooting ladder

When "the internet is down", ping each rung in order. The first one that fails tells you where to look.

| Rung | Command | My result | If this fails… |
|---|---|---|---|
| 1. My own network stack | `ping 127.0.0.1` | <1 ms | The PC's networking is broken |
| 2. The router (LAN / WiFi) | `ping 192.168.0.1` | 1 ms, TTL 64 | WiFi, cable or router problem |
| 3. The internet, by IP | `ping 1.1.1.1` | 22–29 ms, TTL 58 | The ISP link or routing is down |
| 4. The internet, by name | `ping google.com` | 12–35 ms, TTL 116 | **DNS** is broken (rung 3 worked) |
| 5. IPv6 | `ping -6 google.com` | *could not find host* | No IPv6 on this network |

Rung 4 failing while rung 3 works is the classic "WiFi is connected but nothing loads" case: the connection is fine, and only name lookup is broken.

## Latency, jitter and loss

`ping` shows min, average and max. That isn't enough: calls and games suffer from **jitter** (how much the delay jumps around) and **loss**, not just the average. [`ping-stats.ps1`](ping-stats.ps1) adds them:

```powershell
powershell -File ping-stats.ps1 -Target 1.1.1.1 -Count 60
powershell -File ping-stats.ps1 -SelfTest
```

| 60 pings to | Avg | Min | Max | 95th % | Jitter | Loss |
|---|---|---|---|---|---|---|
| Router (WiFi) | 1.7 ms | 1 | 7 | 5 | 1.0 ms | 0% |
| 1.1.1.1 (internet over 5G) | 24.7 ms | 17 | 48 | 37 | 5.2 ms | 0% |

A separate run of 50 pings to 1.1.1.1 lost 1 packet (2%), with a max of 71 ms. Loss comes in bursts, so one short test can miss it.

## TTL: a hint at what's on the other end

Every IP packet starts with a TTL (time to live), and each router subtracts 1. Operating systems pick different starting values: Linux and most routers use **64**, Windows uses **128**, and a lot of network gear uses **255**.

- The router replied with **TTL 64**: it runs Linux. (It does: the router is OpenWrt-based.)
- 1.1.1.1 replied with **58**: probably started at 64, about 6 routers back.
- google.com replied with **116**: probably started at 128, about 12 routers back.

The reply's TTL counts the **return** path, which can differ from the way there, so it's an estimate.

## TTL expired: how traceroute works

```
> ping -n 1 -i 1 1.1.1.1
Reply from 192.168.0.1: TTL expired in transit.

> ping -n 1 -i 3 1.1.1.1
Reply from 10.11.113.1: TTL expired in transit.
```

With TTL set to 1, the first router throws the packet away and sends back "time exceeded", which reveals who it is. Traceroute just does this for TTL 1, 2, 3 and so on until the destination answers.

```
Tracing route to 1.1.1.1
  1     2 ms     2 ms     2 ms  192.168.0.1        my router
  2     *        *        *     Request timed out.  5G core: drops the packet silently
  3    38 ms    18 ms    16 ms  10.11.113.1        private address inside the ISP (CGNAT)
  4    22 ms    17 ms    21 ms  41.216.207.112     ISP backbone
  5    24 ms    32 ms    32 ms  41.216.207.80
  6    20 ms    23 ms    38 ms  41.216.207.65
  7    37 ms    77 ms    40 ms  41.73.54.166       hand-off towards Cloudflare
  8    29 ms    29 ms    32 ms  1.1.1.1
```

A trace to 8.8.8.8 (Google) shares hops 1–5, then splits off towards Google's network (`172.253…`, `192.178…`).

What it shows:

- **`* * *` doesn't mean "broken".** Hop 2 forwards traffic perfectly well (hop 3 answers). It just doesn't send "time exceeded" messages. Many devices are set up this way.
- **A private `10.x` address inside the ISP means carrier-grade NAT (CGNAT).** My router doesn't get its own public IP. The ISP shares one public address among many customers, which is why hosting a server at home or using port forwarding doesn't work on this connection.
- **Latency doesn't only grow along the path.** Hop 7 showed 77 ms once, and the hop after it 29 ms. Routers answer traceroute with low priority, so a slow middle hop is only a problem if the slowness continues to the destination.

## MTU: the biggest packet that fits

Send pings with **Don't Fragment** set, and make them bigger until they fail:

```
> ping -f -l 1472 1.1.1.1      Reply from 1.1.1.1 ...
> ping -f -l 1473 1.1.1.1      Packet needs to be fragmented but DF set.
```

1472 bytes of data, plus 20 bytes of IP header and 8 bytes of ICMP header, makes **1500**: the standard Ethernet/WiFi MTU, all the way to Cloudflare, even over 5G. On PPPoE (common on fibre and DSL) this is often 1492, and VPNs shrink it further. When it's wrong, small pages load but big downloads and some HTTPS sites hang.

## What I learned

1. **Troubleshoot in layers.** Loopback, then router, then internet by IP, then by name. Each rung rules out a whole class of problems, and DNS failures look exactly like "no internet" until you test by IP.
2. **An average hides the problem.** My router averaged 1.7 ms but spiked to 29 ms once, probably WiFi power saving waking the radio. Jitter and the 95th percentile describe the experience better than the mean.
3. **Loss is bursty.** One run of 60 lost nothing, and one run of 50 lost 2%. Test for longer, and at different times, before blaming the line.
4. **TTL works as a fingerprint and as a hop counter.** Starting values (64, 128, 255) hint at the OS, and the gap hints at the distance.
5. **Traceroute is a trick built on TTL errors.** Understanding that explains its quirks: silent hops, private addresses and odd latencies in the middle.
6. **My connection is behind CGNAT.** The `10.x` hop explains why port forwarding can't work on a typical 5G connection.
7. **No IPv6 here.** `ping -6` couldn't even resolve a name. Windows won't look up IPv6 addresses when it has no IPv6 route.
8. **MTU is the size limit nobody sees until it breaks.** Don't Fragment plus a size search finds it in a few pings: 1472 + 28 = 1500.
9. **ICMP is a second-class citizen.** Routers may rate-limit, deprioritise or ignore it. "No reply" doesn't mean "down".

## Commands used

```powershell
ping -n 4 127.0.0.1                # loopback
ping -n 4 192.168.0.1              # router
ping -n 4 1.1.1.1                  # internet by IP
ping -n 4 google.com               # internet by name (DNS)
ping -n 4 -6 google.com            # IPv6
ping -n 50 1.1.1.1                 # longer run for loss
ping -n 1 -f -l 1472 1.1.1.1       # MTU search (-f = Don't Fragment, -l = payload size)
ping -n 1 -i 1 1.1.1.1             # TTL 1: the first router answers
tracert -d -w 1500 1.1.1.1         # traceroute without name lookups
netsh interface ipv4 show subinterfaces   # each adapter's MTU
```
