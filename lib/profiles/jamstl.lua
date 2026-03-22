-- robot profile: jamstl
-- digital chaos sequencer inspired by bastl instruments
-- engine: Jamstl (raw oscillators, bitcrush, FM, moog filter, drums, delay)
--
-- this script is a PLAYGROUND for robot. every param is a chaos vector.
-- the bitcrusher and sample rate are the secret weapons -- sweep them
-- for instant bastl bitranger nastiness. the per-voice chaos system
-- means robot's modulations get amplified by the LFOs inside the engine.
-- delay bits create rhythmic degradation. FM ratio shifts create
-- harmonic surprises. this is where robot gets WEIRD.

return {
  name = "jamstl",
  description = "digital chaos sequencer with bitcrush, FM, drums",
  phrase_len = 16,

  -- 1=FUNK, 2=SPIRITUAL, 3=APHEX, 4=AMBIENT, 5=JAZZ
  -- 6=MINIMALIST, 7=DRUNK, 8=EUCLIDEAN, 9=FRUSCIANTE, 10=CHAOS
  recommended_modes = {3, 10, 1, 7, 2},  -- APHEX, CHAOS, FUNK, DRUNK, SPIRITUAL

  never_touch = {
    "clock_tempo",
    "clock_source",
    "midi_out_ch",
    "midi_in_ch",
    "root_note",
    "scale_type",
    "pattern_length",
    "waveform",
  },

  params = {
    ---------- TIMBRAL (the heart -- filter, bitcrush, FM, noise) ----------

    -- filter: the single most expressive param. robot should LIVE here.
    -- SAFETY: range_lo was 60 which made robot mute everything.
    -- 200hz keeps the low end alive even at minimum.
    cutoff = {
      group = "timbral",
      weight = 1.0,
      sensitivity = 1.2,
      direction = "both",
      range_lo = 200,
      range_hi = 12000,
      euclidean_pulses = 7,
    },

    -- resonance: self-oscillation territory at high values. careful but rewarding.
    res = {
      group = "timbral",
      weight = 0.8,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.0,
      range_hi = 2.8,
      euclidean_pulses = 5,
    },

    -- BIT DEPTH: the bastl bitranger knob. crushing bits = instant character.
    -- sweep from 16 (clean) down to 4 (destroyed). robot's secret weapon.
    bit_depth = {
      group = "timbral",
      weight = 0.9,
      sensitivity = 0.8,
      direction = "both",
      range_lo = 3,
      range_hi = 16,
      euclidean_pulses = 5,
    },

    -- SAMPLE RATE: aliasing city. lower = more artifacts = more bastl.
    sample_rate = {
      group = "timbral",
      weight = 0.7,
      sensitivity = 0.7,
      direction = "both",
      range_lo = 2000,
      range_hi = 40000,
      euclidean_pulses = 9,
    },

    -- FM amount: harmonic complexity. 0=clean, >0.5=metallic, >1=chaos
    fm_amt = {
      group = "timbral",
      weight = 0.7,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0,
      range_hi = 1.2,
      euclidean_pulses = 5,
    },

    -- FM ratio: harmonic vs inharmonic. integers = tonal, decimals = bell/noise
    fm_ratio = {
      group = "timbral",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.5,
      range_hi = 6,
      euclidean_pulses = 3,
    },

    -- pulse width: only matters on pulse wave but adds subtle movement
    pw = {
      group = "timbral",
      weight = 0.4,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.1,
      range_hi = 0.9,
      euclidean_pulses = 7,
    },

    -- sub oscillator: adds weight and low-end presence
    sub_amt = {
      group = "timbral",
      weight = 0.3,
      sensitivity = 0.4,
      direction = "up",
      range_lo = 0,
      range_hi = 0.6,
      euclidean_pulses = 3,
    },

    -- noise: texture layer. pink noise mixed in.
    noise_amt = {
      group = "timbral",
      weight = 0.3,
      sensitivity = 0.3,
      direction = "both",
      range_lo = 0,
      range_hi = 0.4,
      euclidean_pulses = 5,
    },

    ---------- RHYTHMIC (envelope shape, drum character) ----------

    -- attack: 0.005 = percussive, higher = pads/swells
    -- attack: cap at 0.4 so notes don't vanish with short decay
    env_attack = {
      group = "rhythmic",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.001,
      range_hi = 0.4,
      euclidean_pulses = 3,
    },

    -- decay: shapes the note body
    env_decay = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.02,
      range_hi = 1.0,
      euclidean_pulses = 5,
    },

    -- sustain: held level
    env_sustain = {
      group = "rhythmic",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.1,
      range_hi = 0.9,
      euclidean_pulses = 5,
    },

    -- release: tail length
    env_release = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.02,
      range_hi = 2.0,
      euclidean_pulses = 3,
    },

    -- kick tuning: shifting the kick fundamental. subtle but felt.
    kick_tune = {
      group = "rhythmic",
      weight = 0.4,
      sensitivity = 0.3,
      direction = "both",
      range_lo = 40,
      range_hi = 120,
      euclidean_pulses = 3,
    },

    -- kick decay: tight vs boomy
    kick_decay = {
      group = "rhythmic",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.08,
      range_hi = 0.6,
      euclidean_pulses = 5,
    },

    -- hat decay: tight tick vs open wash
    hat_decay = {
      group = "rhythmic",
      weight = 0.3,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.02,
      range_hi = 0.3,
      euclidean_pulses = 7,
    },

    -- KICK PROBABILITY: robot can thin the kick pattern for breakdowns
    kick_prob = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 50,
      range_hi = 100,
      euclidean_pulses = 5,
    },

    -- HAT PROBABILITY: robot can thin hats for builds/drops
    hat_prob = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 40,
      range_hi = 100,
      euclidean_pulses = 7,
    },

    -- KICK GHOST DENSITY: adds ghost kicks between programmed hits.
    -- at 0 only your pattern plays. at 0.5+ it fills in like a real drummer.
    kick_density = {
      group = "rhythmic",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0,
      range_hi = 0.6,
      euclidean_pulses = 5,
    },

    -- HAT GHOST DENSITY: fills in ghost hats. makes static patterns alive.
    -- this is THE fix for repetitive drums. robot adds/removes ghost notes.
    hat_density = {
      group = "rhythmic",
      weight = 0.7,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0,
      range_hi = 0.7,
      euclidean_pulses = 9,
    },

    -- HAT VARIETY: chance of randomizing hat decay per hit.
    -- 0 = identical hats. 0.5+ = mix of open and closed. instant groove.
    hat_variety = {
      group = "rhythmic",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0,
      range_hi = 0.7,
      euclidean_pulses = 7,
    },

    ---------- MELODIC (chaos system, LFOs -- the softpop brain) ----------

    -- CHAOS: the master knob. controls how much the LFOs affect everything.
    -- this is THE param that makes jamstl come alive.
    chaos_amt = {
      group = "melodic",
      weight = 1.0,
      sensitivity = 0.8,
      direction = "both",
      range_lo = 0,
      range_hi = 0.85,
      euclidean_pulses = 7,
    },

    -- LFO1 rate: modulates filter, bitcrush, pan. higher = more frantic.
    lfo1_rate = {
      group = "melodic",
      weight = 0.7,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.05,
      range_hi = 12,
      euclidean_pulses = 5,
    },

    -- LFO2 rate: slower modulation layer (triangle wave)
    lfo2_rate = {
      group = "melodic",
      weight = 0.5,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.02,
      range_hi = 6,
      euclidean_pulses = 3,
    },

    ---------- PERFORMANCE (robot's expressive controls) ----------

    -- NOTE DRIFT: continuous melodic mutation. robot slowly evolves the melody.
    -- at 0 notes are fixed. at 1 every step is a new adventure.
    note_drift = {
      group = "melodic",
      weight = 0.8,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0,
      range_hi = 0.7,
      euclidean_pulses = 5,
    },

    -- GATE LENGTH: staccato vs legato. multiplier on step gate time.
    -- 0.2 = tiny blips, 1.0 = normal, 2.0 = overlapping pads
    gate_length = {
      group = "rhythmic",
      weight = 0.7,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.15,
      range_hi = 1.8,
      euclidean_pulses = 5,
    },

    -- PROBABILITY: global probability scaler. thins out the pattern.
    -- 100 = all steps play, 60 = sparse but present. never fully silent.
    probability = {
      group = "rhythmic",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 55,
      range_hi = 100,
      euclidean_pulses = 7,
    },

    -- PAN: stereo position. robot can create spatial movement.
    pan = {
      group = "timbral",
      weight = 0.5,
      sensitivity = 0.7,
      direction = "both",
      range_lo = -0.8,
      range_hi = 0.8,
      euclidean_pulses = 7,
    },

    -- OCTAVE SHIFT: transpose whole sequence. dramatic but musical.
    octave_shift = {
      group = "structural",
      weight = 0.2,
      sensitivity = 0.2,
      direction = "both",
      range_lo = -1,
      range_hi = 1,
      euclidean_pulses = 3,
    },

    -- SWING: groove feel. 0=straight, 80=heavy shuffle
    swing = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0,
      range_hi = 60,
      euclidean_pulses = 3,
    },

    ---------- STRUCTURAL (FX -- changes the whole vibe) ----------

    -- delay time: rhythmic character of the space
    delay_time = {
      group = "structural",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.05,
      range_hi = 0.8,
      euclidean_pulses = 3,
    },

    -- delay feedback: self-oscillation territory. builds and decays.
    delay_fb = {
      group = "structural",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.1,
      range_hi = 0.85,
      euclidean_pulses = 5,
    },

    -- delay mix: how present the echo is
    delay_mix = {
      group = "structural",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.0,
      range_hi = 0.6,
      euclidean_pulses = 3,
    },

    -- DELAY BITS: bitcrushing the delay independently. lo-fi dub.
    -- this is a bastl thyme signature move.
    delay_bits = {
      group = "structural",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 4,
      range_hi = 16,
      euclidean_pulses = 5,
    },

    -- reverb mix: space and depth
    reverb_mix = {
      group = "structural",
      weight = 0.3,
      sensitivity = 0.3,
      direction = "both",
      range_lo = 0.0,
      range_hi = 0.5,
      euclidean_pulses = 3,
    },

    -- reverb size: intimate vs cavernous
    reverb_size = {
      group = "structural",
      weight = 0.2,
      sensitivity = 0.3,
      direction = "both",
      range_lo = 0.2,
      range_hi = 0.9,
      euclidean_pulses = 3,
    },
  },
}
