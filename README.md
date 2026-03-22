# jamstl

Digital chaos sequencer for [monome norns](https://monome.org/norns/) — inspired by [Bastl Instruments](https://bastl-instruments.com/).

Raw digital oscillators (Kastl), bitcrushing (Bitranger), self-modulating chaos (Softpop), resonant filter (Cinnamon), punchy drums (Tea Kick / Trinity), bitcrushed delay (Thyme), Euclidean rhythms, grid keyboard, and full MIDI I/O.

## Requirements

- monome norns
- optional: monome grid (128)
- optional: MIDI controller / external synth

## Install

```
;install https://github.com/jamminstein/jamstl
```

## Controls

### Norns (standalone)
- **E1**: Page select (PLAY / SOUND / CHAOS / FX)
- **E2/E3**: Context params per page
- **K2**: Play / Stop
- **K3**: Page action (cycle wave, cycle scale, apply Euclidean, toggle delay crush)

### Grid (16x8)
- **Row 1**: Melody step toggles (hold step + press keyboard to set note)
- **Row 2**: Kick pattern
- **Row 3**: Hat pattern
- **Row 4**: Per-step chaos amount (cycles off / low / mid / max)
- **Rows 5-7**: Scale-quantized keyboard (root notes highlighted)
- **Row 8**: Pattern 1-8 | Euclid controls | Randomize | Play | CHAOS!

### The CHAOS! Button
Hold grid button (16, 8) — cranks chaos to maximum and randomizes notes within the current scale. Release to snap back.

### MIDI
- Set MIDI out channel (1-16) to send notes to external gear
- Set MIDI in channel to play live via external controller
- Clock syncs to internal, MIDI, or Link

## Bastl DNA

| Bastl Instrument | jamstl Feature |
|---|---|
| Kastl | Raw digital oscillators (saw/pulse/tri/noise) + FM |
| Bitranger | Bitcrushing + sample rate reduction |
| Softpop | Chaos system — LFOs self-modulate filter, pitch, SR |
| Cinnamon | Resonant Moog filter with chaos modulation |
| Tea Kick | Punchy kick drum with pitch sweep |
| Trinity | Crunchy bitcrushed hi-hat |
| Thyme | Delay with independent bitcrushing + feedback |
| Knit Rider | 16-step sequencer with per-step probability + chaos |
| microGranny | Lo-fi character (12-bit default, 26kHz sample rate) |

## Author

@jamminstein
