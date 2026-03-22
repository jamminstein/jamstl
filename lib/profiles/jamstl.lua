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

    cutoff = {
      group = "timbral",
      weight = 1.0,
      sensitivity = 1.2,
      direction = "both",
      range_lo = 60,
      range_hi = 12000,
      euclidean_pulses = 7,
    },

    res = {
      group = "timbral",
      weight = 0.8,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.0,
      range_hi = 2.8,
      euclidean_pulses = 5,
    },

    bit_depth = {
      group = "timbral",
      weight = 0.9,
      sensitivity = 0.8,
      direction = "both",
      range_lo = 3,
      range_hi = 16,
      euclidean_pulses = 5,
    },

    sample_rate = {
      group = "timbral",
      weight = 0.7,
      sensitivity = 0.7,
      direction = "both",
      range_lo = 2000,
      range_hi = 40000,
      euclidean_pulses = 9,
    },

    fm_amt = {
      group = "timbral",
      weight = 0.7,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0,
      range_hi = 1.2,
      euclidean_pulses = 5,
    },

    fm_ratio = {
      group = "timbral",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.5,
      range_hi = 6,
      euclidean_pulses = 3,
    },

    pw = {
      group = "timbral",
      weight = 0.4,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.1,
      range_hi = 0.9,
      euclidean_pulses = 7,
    },

    sub_amt = {
      group = "timbral",
      weight = 0.3,
      sensitivity = 0.4,
      direction = "up",
      range_lo = 0,
      range_hi = 0.6,
      euclidean_pulses = 3,
    },

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

    env_attack = {
      group = "rhythmic",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.001,
      range_hi = 0.8,
      euclidean_pulses = 3,
    },

    env_decay = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.02,
      range_hi = 1.0,
      euclidean_pulses = 5,
    },

    env_sustain = {
      group = "rhythmic",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.1,
      range_hi = 0.9,
      euclidean_pulses = 5,
    },

    env_release = {
      group = "rhythmic",
      weight = 0.5,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.02,
      range_hi = 2.0,
      euclidean_pulses = 3,
    },

    kick_tune = {
      group = "rhythmic",
      weight = 0.4,
      sensitivity = 0.3,
      direction = "both",
      range_lo = 40,
      range_hi = 120,
      euclidean_pulses = 3,
    },

    kick_decay = {
      group = "rhythmic",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.08,
      range_hi = 0.6,
      euclidean_pulses = 5,
    },

    hat_decay = {
      group = "rhythmic",
      weight = 0.3,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.02,
      range_hi = 0.3,
      euclidean_pulses = 7,
    },

    ---------- MELODIC (chaos system, LFOs -- the softpop brain) ----------

    chaos_amt = {
      group = "melodic",
      weight = 1.0,
      sensitivity = 0.8,
      direction = "both",
      range_lo = 0,
      range_hi = 0.85,
      euclidean_pulses = 7,
    },

    lfo1_rate = {
      group = "melodic",
      weight = 0.7,
      sensitivity = 0.6,
      direction = "both",
      range_lo = 0.05,
      range_hi = 12,
      euclidean_pulses = 5,
    },

    lfo2_rate = {
      group = "melodic",
      weight = 0.5,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 0.02,
      range_hi = 6,
      euclidean_pulses = 3,
    },

    ---------- STRUCTURAL (FX -- changes the whole vibe) ----------

    delay_time = {
      group = "structural",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.05,
      range_hi = 0.8,
      euclidean_pulses = 3,
    },

    delay_fb = {
      group = "structural",
      weight = 0.5,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.1,
      range_hi = 0.85,
      euclidean_pulses = 5,
    },

    delay_mix = {
      group = "structural",
      weight = 0.4,
      sensitivity = 0.4,
      direction = "both",
      range_lo = 0.0,
      range_hi = 0.6,
      euclidean_pulses = 3,
    },

    delay_bits = {
      group = "structural",
      weight = 0.6,
      sensitivity = 0.5,
      direction = "both",
      range_lo = 4,
      range_hi = 16,
      euclidean_pulses = 5,
    },

    reverb_mix = {
      group = "structural",
      weight = 0.3,
      sensitivity = 0.3,
      direction = "both",
      range_lo = 0.0,
      range_hi = 0.5,
      euclidean_pulses = 3,
    },

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
