# Demo

## Local Judge Flow

1. Start anvil.
2. Run `make demo-local`.
3. Review console summary:
   - total in
   - baseline out
   - segmented out
   - slice count
   - improvement bps

## Demo Compare Target

`make demo-compare` runs baseline and segmented scenarios and logs a direct comparison.

## Testnet Demo

Run `make demo-testnet` with chain RPC and private key configured.

For judge walkthroughs, include:

- deployment addresses,
- pool IDs,
- order ID,
- per-slice execution traces.
