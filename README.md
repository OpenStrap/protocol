# OpenStrap protocol

These are the decoders. You hand them an already-unwrapped chunk of bytes from the band,
they hand you back a record with named fields. That's the whole job. No Bluetooth, no
CRCs, no reassembly, just bytes turning into meaning. The
[backend](https://github.com/OpenStrap/backend) calls these server-side to make sense of
the frames your phone uploads.

It's small because it's only the part the production stack actually runs in TypeScript.
If you want the full picture, the byte-by-byte map, the framing, the command set, the sync
handshake, that all lives in the [research repo](https://github.com/OpenStrap/research)
in `PROTOCOL.md`. This is the working subset, ported and trimmed.

> Not affiliated with WHOOP. This is for reading your own band's data.

## The one record that matters most

`parse_r24` decodes the 1 Hz historical record, which is the bulk of what comes off the
band during a sync, one of these per second of wear. Give it the inner payload (89 bytes
or more) and you get back this, or `null` if it's too short:

```ts
interface R24 {
  ts_epoch: number;          // [7:11]   unix seconds
  ts_subsec: number;         // [11:13]
  counter: number;           // [3:7]    goes up by one each record
  hr: number;                // [17]     heart rate, 0 means no reading
  spo2: number;              // [72]     blood oxygen %
  skin_temp_c: number;       // [70]/4   skin temperature in °C
  resting_hr: number;        // [88]     a held baseline, not your live HR
  accel_g: [number, number, number]; // [36:48]  three little-endian floats, in g
  raw_tail: string;          // [13:]    the whole payload as hex, kept untouched
}
```

```ts
import { parse_r24 } from 'openstrap-protocol/ts/records'
const sample = parse_r24(inner)
if (sample) console.log(sample.hr, new Date(sample.ts_epoch * 1000))
```

## What I'm sure of and what I'm not

I want to be honest about this because it's the difference between a decoder you can trust
and one that quietly lies to you.

The header and the heart rate? Solid. I've watched `hr` at byte `[17]` track the live
stream within a beat or two on a band I was actually wearing. That one's real.

Everything after the header is a best guess. The band relays most of this record straight
to WHOOP's cloud without decoding it, so there's no clean reference to check against. The
accelerometer at `[36:48]`, the temperature at `[70]`, the SpO₂ at `[72]`, the resting HR
at `[88]`, I worked those out by watching how the bytes moved against things I could
verify: acceleration sits around 1g when the band is still, the temperature byte climbs
when you put the band on, SpO₂ parks in the low 90s at rest. Plausible. Consistent. Not
confirmed. They're labelled empirical in the code and you should read them that way.

That's also why every record keeps its `raw_tail`: the full payload as hex, nothing
dropped. If someone someday nails down what byte 68 actually is, we re-decode every record
we ever stored and the old data just gets better. Nothing is lost to a bad early guess.

## Where the bytes get unwrapped

You'll notice there's no frame parsing in here, no CRC checks, no `0xAA` handling. By the
time `parse_r24` runs, someone upstream has already pulled the inner payload out of the
frame and confirmed it's intact. That work lives in the clients: the Flutter app
([edge](https://github.com/OpenStrap/edge), in `lib/protocol/`) and the Python reference
client ([research](https://github.com/OpenStrap/research)) each carry their own
reassembler. `PROTOCOL.md` documents the envelope and the packet types if you need to
build one.

## Build it

```bash
npx tsc                          # compile ts/ to dist/
npx tsx ts/test_decoder.ts       # run it against a fixture capture
```

## Adding or fixing a decoder

If you've figured out a field, or want to add `parse_r10` or any of the others on the TS
side, write a function that takes the inner `Uint8Array` and returns a typed object or
`null`. Read multi-byte values little-endian with a `DataView`. Label every field as
verified or empirical, and be honest about which it is, a confident wrong label is worse
than no label. Keep the untouched tail around. And if you've actually pinned down one of
the empirical fields with real evidence, that's exactly the kind of thing I want in an
issue or a PR.
