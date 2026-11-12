# LTE-STRIKE v1.1
## Progressive MiTM Framework for 4G Interception/GTP-C MITM/IMSI Catching/LTE Emulation

![logo](./Logo.png)

**ONLY FOR ENGINEERING & RESEARCH PURPOSES**
**AUTHOR'S DISCLAIMER:**
The author of this tool bears no responsibility for your actions and is not involved in any simulations performed by you. You are solely responsible for compliance with all applicable laws and regulations. Any misuse, illegal activities, or unauthorized testing conducted with this software is entirely your own liability.

**IMPORTANT NOTICE:**
This tool relies exclusively on Andrax-NG utilities revision v1002-unstable (Earthquake).
The software is provided AS-IS. No fixes or updates will be released due to the closure of the Andrax-NG project.
The utilities themselves never had their source code provided and are presented in Andrax as stripped Go binaries

## For your convinience,I provided extracted binaries and YAML configs alredy,so you don't need to investigate for them

## Port mappings may not match default YAML configs,please customize yourself
---

## English Documentation

### Overview
LTE-STRIKE is a comprehensive LTE network testing framework designed for security research and cellular network analysis. It implements a fake LTE core network (MME, SGW, eNodeB) capable of intercepting GTP-C traffic, capturing IMSI data, and performing man-in-the-middle attacks on 4G networks.

### Prerequisites
- Root access on Android device (via Andrax)
- WireGuard VPN connection established
- GTP-U kernel module loaded (optional but recommended)
- tshark for packet analysis
- socat for port redirection
- sslsplit for HTTPS interception (optional)

### Configuration
All configuration files are stored in the same directory as the script:
- `mme.yml` - MME (Mobility Management Entity) configuration
- `sgw.yml` - SGW (Serving Gateway) configuration  
- `enb.yml` - eNodeB (E-UTRAN Node B) configuration

**Important**: Update the `WG_IP` variable in the script to match your WireGuard IP address.

### Usage
```bash
# Full LTE MITM attack
./LTE-STRIKE.sh --full

# Full attack with HTTPS interception
./LTE-STRIKE.sh --full --sslsplit

# Individual components
./LTE-STRIKE.sh --mme
./LTE-STRIKE.sh --sgw  
./LTE-STRIKE.sh --enb

# Monitoring only
./LTE-STRIKE.sh --monitor

# Show status
./LTE-STRIKE.sh --status

# Stop all processes
./LTE-STRIKE.sh --stop
```
# Attack Flow

The script follows this specific execution order:

1. **MME** - Starts the Mobility Management Entity
2. **SGW** - Starts the Serving Gateway
3. **eNodeB** - Starts the fake base station
4. **SOCAT** - Sets up port redirections
5. **Sniffing** - Starts GTP traffic capture
6. **SSLsplit** - Optionally starts HTTPS interception

## Port Mapping

| Port   | Service / Interface          | Redirects to                    |
|--------|-----------------------------|---------------------------------|
| 36412  | S1-MME (MME control plane)  | Fake MME                        |
| 2123   | S11 (MME-SGW interface)     | Fake SGW via WireGuard          |
| 2152   | S1-U (User data)            | Fake eNodeB                     |
| 8080   | HTTPS proxy                 | (if SSLsplit enabled)           |
| 8081   | HTTP proxy                  | (if SSLsplit enabled)           |

## Traffic Capture

- GTP-C control messages are captured to `/data/local/tmp/gtp_traffic.log`
- IMSI numbers are extracted and saved to `/data/local/tmp/imsi_caught.txt`
- Individual component logs: `mme.log`, `sgw.log`, `enb.log`

## Security Considerations

- This tool must only be used on authorized networks
- Always obtain proper permissions before testing
- IMSI data is sensitive personal information
- Follow all applicable laws and regulations

## Troubleshooting

If components fail to start:

1. Verify WireGuard is connected with correct IP
2. Check GTP-U kernel module is loaded: `lsmod | grep gtp`
3. Update `WG_IP` variable in script to match interface IP
4. Verify configuration files exist in script directory
5. Check logs in `/data/local/tmp/` for detailed errors

---

## Legal Disclaimer:

This tool is provided for educational and authorized testing purposes only. The developers assume no liability for misuse. Users are solely responsible for ensuring compliance with all applicable laws and regulations.
