# OpenStrap — protocol

The WHOOP 4.0 record decoders, in TypeScript.

> Not affiliated with or endorsed by WHOOP. For interoperability with hardware you own.

The band speaks a framed BLE protocol and emits a handful of record types — a 1 Hz
historical record, live HR/IMU, optical PPG, events. This package is the parsing
half of that, ported to TypeScript so it can run server-side (it's what the
[backend](https://github.com/OpenStrap/backend) bundles to turn raw frames into
real numbers).

It's deliberately small and pure: bytes in, decoded fields out, no I/O, no state.
The full byte-level reference lives in the
[research repo](https://github.com/OpenStrap/research) (`PROTOCOL.md`); this is the
working code for the parts the cloud-free stack actually needs.

## What's here
- `ts/records.ts` — `parse_r24` (the 1 Hz record: timestamp, HR, and the empirical
  channels) and friends.
- Shared types used across the backend.

Header + heart rate are verified against real hardware; the rest of the 1 Hz record
is empirically fingerprinted and labelled as such — see the research repo for the
confidence breakdown. HRV and the cloud-computed scores are intentionally absent
because the band doesn't expose them.

## Use
```ts
import { parse_r24 } from 'openstrap-protocol/ts/records'
const sample = parse_r24(innerBytes)   // { ts_epoch, hr, ... } or null
```
