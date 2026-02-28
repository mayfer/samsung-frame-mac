# Samsung Frame TV IP Detector (Swift CLI)

A macOS Swift command-line app that scans your local network using Bonjour (`NetServiceBrowser`) and returns Samsung Frame TV IP addresses.

## Build binary

```bash
make
```

This creates a directly runnable binary at:

- `bin/detect-tv-ip`

## Run

```bash
./bin/detect-tv-ip
```

## Output

If multiple Samsung Frame TVs (or multiple Samsung service endpoints) are detected, the tool prints a numbered list.

Example:

```text
Found 2 Samsung TV device(s):
1. 192.168.1.48 ...
2. 192.168.1.49 ...
```
