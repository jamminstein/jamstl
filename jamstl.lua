-- jamstl
-- digital chaos sequencer
-- inspired by bastl instruments
--
-- E1: page select
-- E2/E3: page params
-- K2: play/stop
-- K3: page action
--
-- grid row 1: melody steps
-- grid row 2: kick pattern
-- grid row 3: hat pattern
-- grid row 4: per-step chaos
-- grid rows 5-7: keyboard
-- grid row 8: pattern/controls
--
-- v1.0 @jamminstein

engine.name = "Jamstl"

local musicutil = require "musicutil"
local util = require "util"

---------- CONSTANTS ----------

local NUM_STEPS = 16
local NUM_PATTERNS = 8
local PAGES = {"PLAY", "SOUND", "CHAOS", "FX", "TAPE", "MORPH"}
local WAVE_NAMES = {"saw", "pulse", "tri", "noise"}
local SCALE_NAMES = {"major", "natural_minor", "dorian", "phrygian",
  "mixolydian", "pentatonic_maj", "pentatonic_min", "chromatic"}
local SCALE_DISPLAY = {"MAJ", "MIN", "DOR", "PHR", "MIX", "PNT", "PNm", "CHR"}

---------- STATE ----------

local playing = false
local current_step = 0
local current_pattern = 1
local current_page = 1
local held_step = 0  -- grid: held step for note assignment
local euclid_fills = 8
local euclid_offset = 0
local euclid_track = 1  -- 1=melody 2=kick 3=hat
local chaos_held = false  -- grid chaos button state

-- patterns
local patterns = {}

-- grid
local g = grid.connect()
local grid_dirty = true

-- keyboard note map
local keyboard_notes = {}

-- midi
local midi_out_device
local midi_in_device
local opxy_device

-- screen
local screen_dirty = true
local screen_metro
local particles = {}

-- autopilot (forward declarations — must be before enc/key/redraw)
autopilot_on = false
local autopilot_clock_id = nil
local autopilot_phase = 1
local autopilot_tick = 0
local PHASE_NAMES = {"BUILD", "PEAK", "BREAK", "SPACE"}
local phase_lengths = {16, 8, 12, 10}

-- macro state
local macro_destroy_val = 0
local macro_open_val = 0.5
local drop_active = false
local drop_saved = {}
local snapshot = nil
local k2_held_time = 0
local k2_down = false

-- rungler (kastle shift register)
local rungler_register = {0, 0, 1, 0, 1, 1, 0, 1}  -- seed with some bits
local rungler_value = 0
local rungler_step_count = 0

-- xor drums (bitranger)
local XOR_NAMES = {"OFF", "XOR", "AND", "OR", "NAND"}
local xor_shadow_kick = {}
local xor_shadow_hat = {}

-- pattern chaining
local chain = {}
local chain_pos = 1
local chain_bar = 0
local chain_mode = false
local chain_edit_held = false
local chain_hold_time = 0

-- pattern morph
local pattern_morph_a = 1
local pattern_morph_b = 2

-- snapshot morph
local morph_snapshot = nil
local morph_base = nil

-- tape (softcut)
local tape_mode = 1  -- 1=PLAY, 2=REC, 3=CHOP
local TAPE_MODES = {"PLAY", "REC", "CHOP"}
local tape_speed = 1.0
local tape_rec_length = 0
local tape_recording = false
local tape_playing = false
local tape_phase = 0
local tape_chop_slices = 8
local tape_chop_sel = 1
local TAPE_BUF_SEC = 16

-- cross modulation
local XMOD_NAMES = {"LFO1>LFO2", "STEP>CUT", "NOTE>DLY", "CHAOS>PAN"}

-- clocks
local seq_clock_id
local grid_clock_id

---------- UTILITIES ----------

local function snap_to_scale(note, scale_notes)
  local closest = scale_notes[1]
  local min_dist = 999
  for _, n in ipairs(scale_notes) do
    local d = math.abs(note - n)
    if d < min_dist then
      min_dist = d
      closest = n
    end
  end
  return closest
end

local function euclidean(n, k, offset)
  offset = offset or 0
  local pattern = {}
  local bucket = 0
  for i = 1, n do
    bucket = bucket + k
    if bucket >= n then
      bucket = bucket - n
      pattern[((i - 1 + offset) % n) + 1] = true
    else
      pattern[((i - 1 + offset) % n) + 1] = false
    end
  end
  return pattern
end

---------- PATTERN SAVE/LOAD ----------

local DATA_DIR = _path.data .. "jamstl/"

local function save_patterns()
  util.make_dir(DATA_DIR)
  local data = {
    patterns = {},
    current_pattern = current_pattern,
    chain = chain,
    pattern_morph_a = pattern_morph_a,
    pattern_morph_b = pattern_morph_b,
  }
  for i = 1, NUM_PATTERNS do
    local p = patterns[i]
    local pd = {melody = {}, kick = {}, hat = {}, length = p.length}
    for j = 1, NUM_STEPS do
      pd.melody[j] = {
        on = p.melody[j].on,
        note = p.melody[j].note,
        vel = p.melody[j].vel,
        gate = p.melody[j].gate,
        prob = p.melody[j].prob,
        chaos = p.melody[j].chaos,
      }
      pd.kick[j] = p.kick[j]
      pd.hat[j] = p.hat[j]
    end
    data.patterns[i] = pd
  end
  tab.save(data, DATA_DIR .. "patterns.data")
end

local function load_patterns()
  local path = DATA_DIR .. "patterns.data"
  if util.file_exists(path) then
    local data = tab.load(path)
    if data and data.patterns then
      for i = 1, NUM_PATTERNS do
        if data.patterns[i] then
          local pd = data.patterns[i]
          patterns[i].length = pd.length or 16
          for j = 1, NUM_STEPS do
            if pd.melody and pd.melody[j] then
              patterns[i].melody[j].on = pd.melody[j].on or false
              patterns[i].melody[j].note = pd.melody[j].note or 60
              patterns[i].melody[j].vel = pd.melody[j].vel or 0.8
              patterns[i].melody[j].gate = pd.melody[j].gate or 0.5
              patterns[i].melody[j].prob = pd.melody[j].prob or 100
              patterns[i].melody[j].chaos = pd.melody[j].chaos or 0
            end
            if pd.kick then patterns[i].kick[j] = pd.kick[j] or false end
            if pd.hat then patterns[i].hat[j] = pd.hat[j] or false end
          end
        end
      end
      if data.current_pattern then current_pattern = data.current_pattern end
      if data.chain then chain = data.chain end
      if data.pattern_morph_a then pattern_morph_a = data.pattern_morph_a end
      if data.pattern_morph_b then pattern_morph_b = data.pattern_morph_b end
      return true
    end
  end
  return false
end

---------- RUNGLER ----------

local function rungler_clock()
  rungler_step_count = rungler_step_count + 1
  local div = 1
  if params and params.lookup and params.lookup["rungler_clock_div"] then
    div = ({1, 2, 4, 8})[params:get("rungler_clock_div")]
  end
  if rungler_step_count % div ~= 0 then return end
  -- feedback: XOR of bits 5 and 8
  local new_bit = (rungler_register[5] + rungler_register[8]) % 2
  -- shift left
  for i = 8, 2, -1 do
    rungler_register[i] = rungler_register[i - 1]
  end
  rungler_register[1] = new_bit
  -- compute value 0-255
  rungler_value = 0
  for i = 1, 8 do
    rungler_value = rungler_value + rungler_register[i] * (2 ^ (i - 1))
  end
end

---------- XOR DRUMS ----------

local function update_xor_shadows()
  local kf = params and params:get("xor_kick_fills") or 5
  local hf = params and params:get("xor_hat_fills") or 7
  xor_shadow_kick = euclidean(16, kf, 0)
  xor_shadow_hat = euclidean(16, hf, 3)
end

local function apply_xor_logic(main_hit, shadow_hit, mode)
  if mode == 1 then return main_hit end  -- OFF
  local a = main_hit and 1 or 0
  local b = shadow_hit and 1 or 0
  if mode == 2 then return ((a + b) % 2) == 1      -- XOR
  elseif mode == 3 then return (a * b) == 1          -- AND
  elseif mode == 4 then return (a + b) >= 1           -- OR
  elseif mode == 5 then return (a * b) ~= 1           -- NAND
  end
  return main_hit
end

---------- SNAPSHOT MORPH ----------

local MORPH_PARAMS = {"cutoff", "res", "bit_depth", "sample_rate", "fm_amt",
  "chaos_amt", "delay_mix", "delay_fb", "delay_time", "delay_bits",
  "gate_length", "kick_density", "hat_density", "hat_variety",
  "reverb_mix", "reverb_size", "lfo1_rate", "lfo2_rate"}

local function capture_morph_snapshot()
  morph_snapshot = {}
  morph_base = {}
  for _, k in ipairs(MORPH_PARAMS) do
    morph_snapshot[k] = params:get(k)
    morph_base[k] = params:get(k)
  end
end

local function apply_morph(amt)
  if not morph_snapshot or not morph_base then return end
  for _, k in ipairs(MORPH_PARAMS) do
    local v = morph_base[k] + (morph_snapshot[k] - morph_base[k]) * amt
    params:set(k, v)
  end
end

---------- PATTERN MORPH ----------

local function get_morphed_data(step_idx)
  local m = params:get("pattern_morph_amt")
  local pa = patterns[pattern_morph_a]
  local pb = patterns[pattern_morph_b]
  if not pa or not pb then return nil end
  local len = math.max(pa.length, pb.length)
  if step_idx > len then return nil end

  if m <= 0.01 then
    return pa.melody[step_idx], pa.kick[step_idx], pa.hat[step_idx]
  end
  if m >= 0.99 then
    return pb.melody[step_idx], pb.kick[step_idx], pb.hat[step_idx]
  end

  -- dice per step: use A or B?
  local use_b = math.random() < m
  local src = use_b and pb or pa

  -- blend continuous values
  local step = {
    on = src.melody[step_idx].on,
    note = src.melody[step_idx].note,
    vel = pa.melody[step_idx].vel * (1 - m) + pb.melody[step_idx].vel * m,
    gate = pa.melody[step_idx].gate * (1 - m) + pb.melody[step_idx].gate * m,
    prob = src.melody[step_idx].prob,
    chaos = pa.melody[step_idx].chaos * (1 - m) + pb.melody[step_idx].chaos * m,
  }
  local kick = (math.random() < m) and pb.kick[step_idx] or pa.kick[step_idx]
  local hat = (math.random() < m) and pb.hat[step_idx] or pa.hat[step_idx]
  return step, kick, hat
end

---------- CROSS-MODULATION ----------

local function apply_cross_mod()
  -- LFO1 -> LFO2 rate (continuous)
  local d1 = params:get("xmod_lfo1_lfo2")
  if d1 > 0.01 then
    local lfo1_val = math.sin(util.time() * params:get("lfo1_rate") * 2 * math.pi)
    local new_rate = params:get("lfo2_rate") + lfo1_val * d1 * 8
    engine.lfo2_rate(util.clamp(new_rate, 0.01, 20))
  end

  -- STEP -> CUTOFF (per step, creates filter sweeps)
  local d2 = params:get("xmod_step_cutoff")
  if d2 > 0.01 and current_step > 0 then
    local step_norm = current_step / 16
    local cut_base = params:get("cutoff")
    local cut_mod = (step_norm - 0.5) * d2 * 8000
    engine.cutoff(util.clamp(cut_base + cut_mod, 20, 18000))
  end

  -- NOTE -> DELAY TIME (per step, pitch-tracking echoes)
  local d3 = params:get("xmod_note_delay")
  if d3 > 0.01 and current_step > 0 then
    local p = patterns[current_pattern]
    if p.melody[current_step].on then
      local note = p.melody[current_step].note
      local note_norm = (note - 36) / 48
      local dly_mod = note_norm * d3 * 0.5
      engine.delay_time(util.clamp(params:get("delay_time") + dly_mod, 0.01, 1.5))
    end
  end

  -- CHAOS -> PAN (continuous, stereo scatter)
  local d4 = params:get("xmod_chaos_pan")
  if d4 > 0.01 then
    local chaos = params:get("chaos_amt")
    local pan_mod = (math.random() - 0.5) * chaos * d4 * 1.6
    engine.pan(util.clamp(params:get("pan") + pan_mod, -1, 1))
  end
end

---------- TAPE HELPERS ----------

local function tape_start_rec()
  tape_recording = true
  tape_rec_length = 0
  softcut.buffer_clear_region(1, 0, TAPE_BUF_SEC)
  softcut.position(1, 0)
  softcut.rec(1, 1)
  softcut.play(1, 1)
  tape_mode = 2
end

local function tape_stop_rec()
  tape_recording = false
  softcut.rec(1, 0)
  softcut.play(1, 0)
  if tape_rec_length < 0.1 then tape_rec_length = TAPE_BUF_SEC end
  softcut.loop_end(2, tape_rec_length)
end

local function tape_start_play()
  tape_playing = true
  softcut.position(2, 0)
  softcut.rate(2, params:get("tape_speed"))
  softcut.level(2, params:get("tape_mix"))
  softcut.loop(2, 1)
  softcut.play(2, 1)
  tape_mode = 1
end

local function tape_stop_play()
  tape_playing = false
  softcut.play(2, 0)
end

local function tape_enter_chop()
  tape_mode = 3
  tape_chop_sel = 1
  -- loop within first slice
  if tape_rec_length > 0 then
    local slice_len = tape_rec_length / tape_chop_slices
    softcut.loop_start(2, 0)
    softcut.loop_end(2, slice_len)
    softcut.position(2, 0)
    softcut.play(2, 1)
    tape_playing = true
  end
end

---------- PATTERN DATA ----------

local function new_step()
  return {on = false, note = 60, vel = 0.8, gate = 0.5, prob = 100, chaos = 0}
end

local function new_pattern()
  local p = {melody = {}, kick = {}, hat = {}, length = 16}
  for i = 1, NUM_STEPS do
    p.melody[i] = new_step()
    p.kick[i] = false
    p.hat[i] = false
  end
  return p
end

local function set_pattern(idx, notes, on_steps, vels, chaos_steps, kick, hat)
  local p = patterns[idx]
  for i = 1, 16 do
    p.melody[i].note = notes[i] or 60
    p.melody[i].on = on_steps[i] == 1
    p.melody[i].vel = vels[i] or 0.7
    p.melody[i].chaos = chaos_steps[i] or 0
    p.melody[i].gate = (vels[i] and vels[i] > 0.85) and 0.7 or 0.4
  end
  for i = 1, 16 do
    p.kick[i] = kick[i] == 1
    p.hat[i] = hat[i] == 1
  end
end

local function init_default_patterns()
  for i = 1, NUM_PATTERNS do
    patterns[i] = new_pattern()
  end

  -- P1: FUNK — syncopated kick, offbeat hats, pentatonic riff
  set_pattern(1,
    {60, 63, 65, 67, 72, 70, 67, 63, 60, 65, 70, 72, 67, 63, 65, 60},
    {1,  0,  1,  1,  0,  1,  0,  1,  1,  0,  1,  0,  1,  0,  0,  1},
    {1., .5, .8, .6, .5, .9, .5, .7, 1., .5, .8, .5, .7, .4, .3, .6},
    {0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  .3, 0,  .3, .5, 0},
    {1,  0,  0,  1,  0,  0,  1,  0,  0,  1,  0,  0,  1,  0,  1,  0},
    {0,  0,  1,  0,  1,  0,  1,  1,  0,  0,  1,  0,  1,  1,  0,  1})

  -- P2: ACID — 303-style, heavy on the one, ghost notes, rolling hats
  set_pattern(2,
    {48, 48, 60, 51, 53, 48, 60, 55, 48, 51, 63, 60, 53, 48, 55, 51},
    {1,  1,  1,  0,  1,  1,  0,  1,  1,  0,  1,  1,  0,  1,  0,  1},
    {1., .4, .9, .3, .6, 1., .3, .7, .9, .3, .8, .5, .4, 1., .3, .5},
    {0,  0,  0,  0,  .4, 0,  0,  .3, 0,  0,  0,  .5, 0,  0,  .6, 0},
    {1,  0,  0,  0,  1,  0,  1,  0,  0,  0,  1,  0,  1,  0,  0,  1},
    {1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1})

  -- P3: BROKEN — irregular kick, sparse hat, chromatic stabs
  set_pattern(3,
    {63, 66, 60, 68, 61, 65, 63, 70, 60, 67, 64, 72, 63, 61, 68, 60},
    {1,  0,  0,  1,  0,  1,  0,  0,  1,  0,  0,  1,  0,  1,  0,  0},
    {1., .5, .3, .9, .4, .7, .3, .5, 1., .4, .3, .8, .5, .6, .4, .3},
    {.3, 0,  0,  .5, 0,  .4, 0,  0,  .3, 0,  0,  .6, 0,  .5, 0,  0},
    {1,  0,  0,  0,  0,  0,  1,  0,  0,  1,  0,  0,  0,  0,  1,  0},
    {0,  0,  1,  0,  0,  1,  0,  0,  1,  0,  0,  1,  0,  0,  0,  1})

  -- P4: MINIMAL — sparse, heavy spaces, low notes
  set_pattern(4,
    {48, 48, 55, 48, 48, 53, 48, 48, 48, 55, 48, 48, 53, 48, 48, 48},
    {1,  0,  0,  0,  0,  0,  1,  0,  0,  0,  1,  0,  0,  0,  0,  0},
    {1., .3, .3, .3, .3, .3, .8, .3, .3, .3, .7, .3, .3, .3, .3, .3},
    {0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0},
    {1,  0,  0,  0,  0,  0,  0,  0,  1,  0,  0,  0,  0,  0,  0,  0},
    {0,  0,  0,  0,  1,  0,  0,  0,  0,  0,  0,  0,  1,  0,  0,  0})

  -- P5: POLYRHYTHM — 3-over-4 kick, euclidean hat, ascending melody
  set_pattern(5,
    {60, 62, 63, 65, 67, 68, 70, 72, 70, 68, 67, 65, 63, 62, 60, 58},
    {1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0},
    {.9, .4, .7, .4, .8, .4, .7, .4, .9, .4, .7, .4, .8, .4, .7, .4},
    {0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  .3, .3, .4, .5},
    {1,  0,  0,  1,  0,  0,  1,  0,  0,  1,  0,  0,  1,  0,  0,  0},
    {1,  0,  0,  1,  0,  1,  0,  0,  1,  0,  1,  0,  0,  1,  0,  1})

  -- P6: BASTL CHAOS — everything on, high chaos, dense and glitchy
  set_pattern(6,
    {72, 60, 75, 63, 70, 58, 67, 65, 73, 61, 68, 60, 72, 63, 67, 70},
    {1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  0,  1,  1,  1,  1,  0},
    {.8, .6, .9, .5, .7, .3, .8, .6, .9, .5, .3, .7, .8, .6, .9, .4},
    {.5, .3, .6, .4, .7, 0,  .5, .3, .8, .4, 0,  .6, .5, .4, .7, 0},
    {1,  0,  1,  0,  1,  0,  0,  1,  0,  1,  0,  1,  0,  0,  1,  0},
    {1,  1,  0,  1,  1,  0,  1,  0,  1,  1,  0,  1,  0,  1,  1,  0})

  -- P7: HALFTIME — slow heavy, kick on 1 and 9, snappy hats
  set_pattern(7,
    {48, 48, 55, 53, 48, 48, 51, 48, 48, 55, 53, 51, 48, 48, 51, 53},
    {1,  0,  0,  0,  1,  0,  0,  0,  1,  0,  0,  0,  1,  0,  0,  1},
    {1., .3, .3, .3, .8, .3, .3, .3, 1., .3, .3, .3, .7, .3, .3, .6},
    {0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  .3, 0,  .4, .5},
    {1,  0,  0,  0,  0,  0,  0,  0,  1,  0,  0,  0,  0,  0,  0,  0},
    {0,  0,  0,  0,  1,  0,  1,  0,  0,  0,  0,  0,  1,  0,  1,  0})

  -- P8: FILL — dense 16th fills, all drums, high energy transition
  set_pattern(8,
    {72, 70, 67, 65, 63, 60, 63, 65, 67, 70, 72, 75, 72, 70, 67, 65},
    {1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
    {.6, .5, .7, .5, .8, .5, .6, .5, .7, .5, .8, .6, .9, .7, 1., .8},
    {.2, .2, .3, .2, .3, .2, .3, .3, .4, .3, .4, .4, .5, .5, .6, .7},
    {1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  1,  1,  1},
    {0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  1,  1,  1,  1})
end

---------- RANDOMIZE PATTERNS ----------

local function randomize_all_patterns()
  -- pick a random root and scale for generation
  local root = 48 + math.random(0, 12)
  local scale_idx = math.random(1, #SCALE_NAMES)
  local scale = musicutil.generate_scale(root, SCALE_NAMES[scale_idx], 4)

  -- drum rhythm templates: euclidean fills + offsets for variety
  local kick_templates = {
    {fills = 4, offset = 0},   -- four on the floor
    {fills = 3, offset = 0},   -- 3/4 feel
    {fills = 5, offset = 0},   -- funky 5
    {fills = 2, offset = 0},   -- halftime
    {fills = 6, offset = 2},   -- dense syncopated
    {fills = 4, offset = 1},   -- offbeat four
    {fills = 3, offset = 2},   -- displaced triplet
    {fills = 7, offset = 0},   -- breakbeat dense
  }
  local hat_templates = {
    {fills = 8, offset = 0},   -- 8ths
    {fills = 6, offset = 1},   -- syncopated
    {fills = 12, offset = 0},  -- busy 16ths
    {fills = 4, offset = 2},   -- sparse
    {fills = 10, offset = 3},  -- almost all
    {fills = 5, offset = 1},   -- euclidean 5
    {fills = 7, offset = 2},   -- euclidean 7
    {fills = 9, offset = 0},   -- 9/16
  }

  for i = 1, NUM_PATTERNS do
    local p = patterns[i]

    -- pick density: how many melody steps are active (4-12)
    local density = 4 + math.random(0, 8)
    local melody_euclid = euclidean(16, density, math.random(0, 5))

    -- generate melody: walk through scale with occasional leaps
    local note_idx = math.random(1, math.floor(#scale * 0.6))
    for j = 1, 16 do
      p.melody[j].on = melody_euclid[j] or false
      -- random walk through scale
      note_idx = note_idx + math.random(-2, 2)
      note_idx = util.clamp(note_idx, 1, #scale)
      p.melody[j].note = scale[note_idx]
      -- varied velocities with accents on downbeats
      p.melody[j].vel = (j % 4 == 1) and (0.7 + math.random() * 0.3) or (0.4 + math.random() * 0.4)
      -- gate variation
      p.melody[j].gate = 0.3 + math.random() * 0.6
      -- probability: mostly 100, occasional drops
      p.melody[j].prob = math.random() < 0.15 and (60 + math.random(30)) or 100
      -- chaos: sparse, mostly on later steps
      p.melody[j].chaos = (j > 10 and math.random() < 0.4) and (math.random() * 0.6) or 0
    end

    -- drums: pick from templates, each pattern gets a different feel
    local kt = kick_templates[((i - 1) % #kick_templates) + 1]
    local ht = hat_templates[((i + 2) % #hat_templates) + 1]
    -- add randomness to template choice
    if math.random() < 0.5 then
      kt = kick_templates[math.random(1, #kick_templates)]
    end
    if math.random() < 0.5 then
      ht = hat_templates[math.random(1, #hat_templates)]
    end

    local kick_e = euclidean(16, kt.fills, kt.offset + math.random(0, 3))
    local hat_e = euclidean(16, ht.fills, ht.offset + math.random(0, 3))
    for j = 1, 16 do
      p.kick[j] = kick_e[j] or false
      p.hat[j] = hat_e[j] or false
    end

    -- pattern length: mostly 16 but occasionally shorter for polyrhythm
    p.length = ({16, 16, 16, 16, 12, 14, 16, 8})[math.random(1, 8)]
  end
end

---------- MANUAL SAVE/LOAD SLOTS ----------

local NUM_SAVE_SLOTS = 8

local function save_to_slot(slot)
  util.make_dir(DATA_DIR)
  local data = {patterns = {}, current_pattern = current_pattern, chain = chain}
  for i = 1, NUM_PATTERNS do
    local p = patterns[i]
    local pd = {melody = {}, kick = {}, hat = {}, length = p.length}
    for j = 1, NUM_STEPS do
      pd.melody[j] = {
        on = p.melody[j].on, note = p.melody[j].note, vel = p.melody[j].vel,
        gate = p.melody[j].gate, prob = p.melody[j].prob, chaos = p.melody[j].chaos,
      }
      pd.kick[j] = p.kick[j]
      pd.hat[j] = p.hat[j]
    end
    data.patterns[i] = pd
  end
  tab.save(data, DATA_DIR .. "slot_" .. slot .. ".data")
end

local function load_from_slot(slot)
  local path = DATA_DIR .. "slot_" .. slot .. ".data"
  if util.file_exists(path) then
    local data = tab.load(path)
    if data and data.patterns then
      for i = 1, NUM_PATTERNS do
        if data.patterns[i] then
          local pd = data.patterns[i]
          patterns[i].length = pd.length or 16
          for j = 1, NUM_STEPS do
            if pd.melody and pd.melody[j] then
              patterns[i].melody[j].on = pd.melody[j].on or false
              patterns[i].melody[j].note = pd.melody[j].note or 60
              patterns[i].melody[j].vel = pd.melody[j].vel or 0.8
              patterns[i].melody[j].gate = pd.melody[j].gate or 0.5
              patterns[i].melody[j].prob = pd.melody[j].prob or 100
              patterns[i].melody[j].chaos = pd.melody[j].chaos or 0
            end
            if pd.kick then patterns[i].kick[j] = pd.kick[j] or false end
            if pd.hat then patterns[i].hat[j] = pd.hat[j] or false end
          end
        end
      end
      if data.current_pattern then current_pattern = data.current_pattern end
      if data.chain then chain = data.chain end
      update_keyboard()
      return true
    end
  end
  return false
end

local function slot_exists(slot)
  return util.file_exists(DATA_DIR .. "slot_" .. slot .. ".data")
end

---------- KEYBOARD MAP ----------

local function update_keyboard()
  keyboard_notes = {}
  local root = params:get("root_note")
  local scale_name = SCALE_NAMES[params:get("scale_type")]
  local notes = musicutil.generate_scale(root, scale_name, 6)
  local idx = 1
  for row = 7, 5, -1 do
    keyboard_notes[row] = {}
    for col = 1, 16 do
      if idx <= #notes then
        keyboard_notes[row][col] = notes[idx]
        idx = idx + 1
      end
    end
  end
end

---------- PARTICLES (chaos visualization) ----------

local function update_particles()
  local chaos = params:get("chaos_amt")
  if chaos > 0.05 and math.random() < chaos * 0.4 then
    table.insert(particles, {
      x = math.random(0, 127),
      y = math.random(32, 63),
      vx = (math.random() - 0.5) * chaos * 6,
      vy = (math.random() - 0.5) * chaos * 4,
      life = math.random(4, 12),
      bright = math.random(2, 8)
    })
  end
  for i = #particles, 1, -1 do
    local p = particles[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.life = p.life - 1
    if p.life <= 0 or p.x < 0 or p.x > 127 or p.y < 0 or p.y > 63 then
      table.remove(particles, i)
    end
  end
end

---------- MIDI HELPERS ----------

local function midi_note_on(note, vel_int, ch)
  if midi_out_device and params:get("midi_out_ch") > 0 then
    midi_out_device:note_on(note, vel_int, ch or params:get("midi_out_ch"))
  end
end

local function midi_note_off(note, ch)
  if midi_out_device and params:get("midi_out_ch") > 0 then
    midi_out_device:note_off(note, 0, ch or params:get("midi_out_ch"))
  end
end

local function opxy_note_on(note, vel_int, ch)
  if opxy_device and params:get("opxy_device") > 1 then
    opxy_device:note_on(note, vel_int, ch)
  end
end

local function opxy_note_off(note, ch)
  if opxy_device and params:get("opxy_device") > 1 then
    opxy_device:note_off(note, 0, ch)
  end
end

local function opxy_cc(cc, val, ch)
  if opxy_device and params:get("opxy_device") > 1 then
    opxy_device:cc(cc, val, ch)
  end
end

---------- NOTE PLAYBACK ----------

local function play_note(note, vel, gate_time)
  local freq = musicutil.note_num_to_freq(note)
  local vel_int = math.floor(vel * 127)
  engine.note_on(note, freq, vel)
  -- standard MIDI out
  midi_note_on(note, vel_int)
  -- OP-XY: melody on dedicated channel
  local opxy_mel_ch = params:get("opxy_melody_ch")
  opxy_note_on(note, vel_int, opxy_mel_ch)
  clock.run(function()
    clock.sleep(gate_time)
    engine.note_off(note)
    midi_note_off(note)
    opxy_note_off(note, opxy_mel_ch)
  end)
end

local function play_live_note(note, vel)
  local freq = musicutil.note_num_to_freq(note)
  local vel_int = math.floor(vel * 127)
  engine.note_on(note, freq, vel)
  midi_note_on(note, vel_int)
  opxy_note_on(note, vel_int, params:get("opxy_melody_ch"))
end

local function stop_live_note(note)
  engine.note_off(note)
  midi_note_off(note)
  opxy_note_off(note, params:get("opxy_melody_ch"))
end

---------- SEQUENCER ----------

local function advance_step()
  local p = patterns[current_pattern]
  current_step = (current_step % p.length) + 1

  -- PATTERN CHAINING: auto-switch after N bars
  if chain_mode and #chain > 0 and current_step == 1 then
    chain_bar = chain_bar + 1
    if chain_bar > chain[chain_pos].bars then
      chain_bar = 1
      chain_pos = (chain_pos % #chain) + 1
      current_pattern = chain[chain_pos].pattern
      p = patterns[current_pattern]
      update_keyboard()
    end
  end

  -- RUNGLER: clock the shift register
  rungler_clock()

  local beat_dur = clock.get_beat_sec() / 4

  -- PATTERN MORPH: get blended step data if morph active
  local step, raw_kick, raw_hat
  local morph_amt = params:get("pattern_morph_amt")
  if morph_amt > 0.01 then
    step, raw_kick, raw_hat = get_morphed_data(current_step)
    if not step then step = p.melody[current_step] end
    if raw_kick == nil then raw_kick = p.kick[current_step] end
    if raw_hat == nil then raw_hat = p.hat[current_step] end
  else
    step = p.melody[current_step]
    raw_kick = p.kick[current_step]
    raw_hat = p.hat[current_step]
  end

  -- XOR DRUMS: apply bit logic to drum patterns
  local xor_mode = params:get("xor_mode")
  if xor_mode > 1 then
    raw_kick = apply_xor_logic(raw_kick, xor_shadow_kick[current_step], xor_mode)
    raw_hat = apply_xor_logic(raw_hat, xor_shadow_hat[current_step], xor_mode)
  end

  -- RUNGLER modulation values
  local rung_amt = params:get("rungler_amt")
  local rung_norm = rungler_value / 255

  -- ===== MELODY =====
  if step.on then
    local step_chaos = step.chaos
    local drift = params:get("note_drift")
    local total_chaos = step_chaos + drift
    if total_chaos > 0 then
      engine.chaos(params:get("chaos_amt") + step_chaos)
    end
    local effective_prob = step.prob * (params:get("probability") / 100)
    if math.random(100) <= effective_prob then
      local note = step.note + (params:get("octave_shift") * 12)
      local vel = step.vel
      local scale_notes = musicutil.generate_scale(
        params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 5)

      -- rungler note offset
      if rung_amt > 0.01 then
        local rung_offset = math.floor((rung_norm - 0.5) * 14 * rung_amt)
        note = snap_to_scale(note + rung_offset, scale_notes)
      end

      -- chaos note drift
      if total_chaos > 0 and math.random() < total_chaos * 0.4 then
        local drift_amt = math.floor(total_chaos * 4)
        note = snap_to_scale(note + math.random(-drift_amt, drift_amt), scale_notes)
      end
      -- velocity variation
      if total_chaos > 0 then
        vel = util.clamp(vel + (math.random() - 0.5) * total_chaos * 0.3, 0.1, 1.0)
      end

      -- rungler filter modulation
      if rung_amt > 0.01 then
        local cut_mod = (rung_norm - 0.5) * 6000 * rung_amt
        engine.cutoff(util.clamp(params:get("cutoff") + cut_mod, 20, 18000))
      end

      local gate = beat_dur * step.gate * 2 * params:get("gate_length")
      play_note(note, vel, gate)
    end
    if total_chaos > 0 then
      engine.chaos(params:get("chaos_amt"))
    end
    -- restore cutoff after rungler mod
    if rung_amt > 0.01 then
      engine.cutoff(params:get("cutoff"))
    end
  end

  -- ===== KICK =====
  local kick_prob = params:get("kick_prob")
  local kick_density = params:get("kick_density")
  local should_kick = raw_kick
  if not should_kick and kick_density > 0 and math.random() < kick_density * 0.3 then
    should_kick = true
  end
  -- rungler ghost kicks
  if not should_kick and rung_amt > 0.3 and rungler_register[3] == 1 then
    should_kick = true
  end
  if should_kick and math.random(100) <= kick_prob then
    local vel = (current_step % 4 == 1) and 1.0 or 0.75
    if not raw_kick then vel = vel * 0.4 end
    vel = util.clamp(vel + (math.random() - 0.5) * 0.15, 0.2, 1.0)
    local vel_int = math.floor(vel * 127)
    engine.kick(vel)
    midi_note_on(36, vel_int)
    local opxy_drum_ch = params:get("opxy_drum_ch")
    opxy_note_on(36, vel_int, opxy_drum_ch)
    clock.run(function()
      clock.sleep(0.05)
      midi_note_off(36)
      opxy_note_off(36, opxy_drum_ch)
    end)
  end

  -- ===== HAT =====
  local hat_prob = params:get("hat_prob")
  local hat_density = params:get("hat_density")
  local should_hat = raw_hat
  if not should_hat and hat_density > 0 and math.random() < hat_density * 0.4 then
    should_hat = true
  end
  -- rungler ghost hats
  if not should_hat and rung_amt > 0.4 and rungler_register[6] == 1 then
    should_hat = true
  end
  if should_hat and math.random(100) <= hat_prob then
    local vel = 0.4 + math.random() * 0.2
    if not raw_hat then vel = vel * 0.35 end
    local hat_var = params:get("hat_variety")
    if hat_var > 0 and math.random() < hat_var then
      engine.hat_decay(params:get("hat_decay") * (0.5 + math.random() * 2.0))
    end
    vel = util.clamp(vel + (math.random() - 0.5) * 0.12, 0.15, 0.8)
    local vel_int = math.floor(vel * 127)
    engine.hat(vel)
    midi_note_on(42, vel_int)
    local opxy_drum_ch = params:get("opxy_drum_ch")
    opxy_note_on(42, vel_int, opxy_drum_ch)
    clock.run(function()
      clock.sleep(0.05)
      midi_note_off(42)
      opxy_note_off(42, opxy_drum_ch)
    end)
    if hat_var > 0 then
      engine.hat_decay(params:get("hat_decay"))
    end
  end

  -- CROSS-MOD: step-based modulations
  apply_cross_mod()

  -- tape recording length tracking
  if tape_recording then
    tape_rec_length = tape_rec_length + beat_dur
    if tape_rec_length >= TAPE_BUF_SEC then
      tape_stop_rec()
      tape_start_play()
    end
  end

  screen_dirty = true
  grid_dirty = true
end

local function start_sequencer()
  playing = true
  current_step = 0
  seq_clock_id = clock.run(function()
    while true do
      clock.sync(1/4)
      if playing then
        advance_step()
      end
    end
  end)
end

local function stop_sequencer()
  playing = false
  current_step = 0
  if seq_clock_id then
    clock.cancel(seq_clock_id)
    seq_clock_id = nil
  end
  screen_dirty = true
  grid_dirty = true
end

---------- APPLY EUCLIDEAN ----------

local function apply_euclidean()
  local p = patterns[current_pattern]
  local e = euclidean(p.length, euclid_fills, euclid_offset)
  if euclid_track == 1 then
    for i = 1, p.length do p.melody[i].on = e[i] end
  elseif euclid_track == 2 then
    for i = 1, p.length do p.kick[i] = e[i] end
  elseif euclid_track == 3 then
    for i = 1, p.length do p.hat[i] = e[i] end
  end
  grid_dirty = true
  screen_dirty = true
end

---------- CHAOS BUTTON ----------

local saved_chaos = 0

local function chaos_engage()
  chaos_held = true
  saved_chaos = params:get("chaos_amt")
  params:set("chaos_amt", 1.0)
  -- randomize some params within musical bounds
  local p = patterns[current_pattern]
  for i = 1, p.length do
    if p.melody[i].on and math.random() < 0.4 then
      local scale_notes = musicutil.generate_scale(
        params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 4)
      p.melody[i].note = scale_notes[math.random(#scale_notes)]
    end
  end
end

local function chaos_release()
  chaos_held = false
  params:set("chaos_amt", saved_chaos)
end

---------- GRID ----------

g.key = function(x, y, z)
  local p = patterns[current_pattern]

  if z == 1 then
    -- ROW 1: melody step toggles
    if y == 1 and x <= p.length then
      if held_step == 0 then
        p.melody[x].on = not p.melody[x].on
      end
      held_step = x  -- remember for note assignment

    -- ROW 2: kick pattern
    elseif y == 2 and x <= p.length then
      p.kick[x] = not p.kick[x]

    -- ROW 3: hat pattern
    elseif y == 3 and x <= p.length then
      p.hat[x] = not p.hat[x]

    -- ROW 4: per-step chaos (cycle 0 > 0.3 > 0.6 > 1.0)
    elseif y == 4 and x <= p.length then
      local c = p.melody[x].chaos
      if c < 0.1 then c = 0.3
      elseif c < 0.4 then c = 0.6
      elseif c < 0.7 then c = 1.0
      else c = 0 end
      p.melody[x].chaos = c

    -- ROWS 5-7: keyboard
    elseif y >= 5 and y <= 7 then
      if keyboard_notes[y] and keyboard_notes[y][x] then
        local note = keyboard_notes[y][x]
        if held_step > 0 then
          -- assign note to held step
          p.melody[held_step].note = note
          p.melody[held_step].on = true
        else
          -- live play
          play_live_note(note, 0.8)
        end
      end

    -- ROW 8: controls
    elseif y == 8 then
      if x == 9 then
        -- CHAIN button
        chain_edit_held = true
        chain_hold_time = util.time()
      elseif x >= 1 and x <= 8 then
        if chain_edit_held then
          -- append to chain
          table.insert(chain, {pattern = x, bars = 1})
        else
          -- pattern select
          current_pattern = x
          update_keyboard()
        end
      elseif x == 10 then
        -- euclidean track cycle
        euclid_track = (euclid_track % 3) + 1
      elseif x == 11 then
        -- euclidean fills down
        euclid_fills = math.max(0, euclid_fills - 1)
        apply_euclidean()
      elseif x == 12 then
        -- euclidean fills up
        euclid_fills = math.min(16, euclid_fills + 1)
        apply_euclidean()
      elseif x == 13 then
        -- euclidean offset
        euclid_offset = (euclid_offset + 1) % 16
        apply_euclidean()
      elseif x == 14 then
        -- randomize active step notes (within scale)
        local scale_notes = musicutil.generate_scale(
          params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 3)
        for i = 1, p.length do
          if p.melody[i].on then
            p.melody[i].note = scale_notes[math.random(#scale_notes)]
          end
        end
      elseif x == 15 then
        -- play/stop
        if playing then stop_sequencer() else start_sequencer() end
      elseif x == 16 then
        -- CHAOS!
        chaos_engage()
      end
    end

  else -- z == 0 (release)
    if y == 1 then
      held_step = 0
    elseif y >= 5 and y <= 7 then
      if keyboard_notes[y] and keyboard_notes[y][x] then
        if held_step == 0 then
          stop_live_note(keyboard_notes[y][x])
        end
      end
    elseif y == 8 and x == 16 then
      chaos_release()
    elseif y == 8 and x == 9 then
      -- chain button release
      chain_edit_held = false
      local held = util.time() - chain_hold_time
      if held > 1.0 then
        -- long press: clear chain
        chain = {}
        chain_mode = false
        chain_pos = 1
        chain_bar = 0
      else
        -- short tap: toggle chain playback
        if #chain > 0 then
          chain_mode = not chain_mode
          if chain_mode then
            chain_pos = 1
            chain_bar = 0
            current_pattern = chain[1].pattern
            update_keyboard()
          end
        end
      end
    end
  end

  grid_dirty = true
  screen_dirty = true
end

local function grid_redraw()
  g:all(0)
  local p = patterns[current_pattern]

  -- row 1: melody steps
  for x = 1, p.length do
    local brightness = 0
    if x == current_step and playing then
      brightness = 15
    elseif p.melody[x].on then
      brightness = 8
    else
      brightness = 2
    end
    g:led(x, 1, brightness)
  end

  -- row 2: kick
  for x = 1, p.length do
    local b = 2
    if p.kick[x] then b = (x == current_step and playing) and 15 or 10 end
    if x == current_step and playing and p.kick[x] then b = 15 end
    g:led(x, 2, b)
  end

  -- row 3: hat
  for x = 1, p.length do
    local b = 2
    if p.hat[x] then b = (x == current_step and playing) and 15 or 7 end
    g:led(x, 3, b)
  end

  -- row 4: per-step chaos
  for x = 1, p.length do
    local c = p.melody[x].chaos
    local b = 0
    if c > 0.8 then b = 15
    elseif c > 0.5 then b = 10
    elseif c > 0.1 then b = 5
    else b = 1 end
    g:led(x, 4, b)
  end

  -- rows 5-7: keyboard
  for row = 5, 7 do
    if keyboard_notes[row] then
      for col = 1, 16 do
        if keyboard_notes[row][col] then
          local note = keyboard_notes[row][col]
          local b = 3
          -- highlight root notes
          if note % 12 == params:get("root_note") % 12 then
            b = 8
          end
          -- highlight if matches held step's note
          if held_step > 0 and p.melody[held_step].note == note then
            b = 15
          end
          g:led(col, row, b)
        end
      end
    end
  end

  -- row 8: controls
  for x = 1, 8 do
    if chain_edit_held then
      -- show chain contents
      local in_chain = false
      for _, entry in ipairs(chain) do
        if entry.pattern == x then in_chain = true; break end
      end
      g:led(x, 8, in_chain and 12 or 2)
    else
      g:led(x, 8, x == current_pattern and 15 or 3)
    end
  end
  -- col 9: chain button
  g:led(9, 8, chain_mode and (#chain > 0 and 12 or 4) or (chain_edit_held and 15 or (#chain > 0 and 6 or 2)))
  -- euclidean track indicator
  g:led(10, 8, ({8, 10, 6})[euclid_track])
  g:led(11, 8, 4)  -- fills down
  g:led(12, 8, 4)  -- fills up
  g:led(13, 8, 4)  -- offset
  g:led(14, 8, 6)  -- randomize
  g:led(15, 8, playing and 15 or 4)  -- play/stop
  g:led(16, 8, chaos_held and 15 or 8)  -- CHAOS!

  g:refresh()
end

---------- MACRO SNAPSHOTS (saved/recalled by keys) ----------

local function save_snapshot()
  snapshot = {
    cutoff = params:get("cutoff"),
    res = params:get("res"),
    bit_depth = params:get("bit_depth"),
    sample_rate = params:get("sample_rate"),
    fm_amt = params:get("fm_amt"),
    chaos_amt = params:get("chaos_amt"),
    delay_mix = params:get("delay_mix"),
    delay_fb = params:get("delay_fb"),
    gate_length = params:get("gate_length"),
    kick_density = params:get("kick_density"),
    hat_density = params:get("hat_density"),
    hat_variety = params:get("hat_variety"),
  }
end

local function recall_snapshot()
  if not snapshot then return end
  for k, v in pairs(snapshot) do
    params:set(k, v)
  end
end

---------- MACRO FUNCTIONS ----------

-- DESTROY: bitcrush + resonance spike + delay feedback surge
local function macro_destroy(amount)
  local amt = util.clamp(amount, 0, 1)
  params:set("bit_depth", util.clamp(16 - amt * 13, 3, 16))
  params:set("sample_rate", util.clamp(40000 - amt * 36000, 2000, 40000))
  params:set("res", util.clamp(0.3 + amt * 2.5, 0.3, 3.0))
  params:set("delay_fb", util.clamp(0.4 + amt * 0.45, 0.4, 0.85))
end

-- OPEN: filter sweep + FM + reverb bloom
local function macro_open(amount)
  local amt = util.clamp(amount, 0, 1)
  params:set("cutoff", 200 + amt * 11800)
  params:set("fm_amt", amt * 0.8)
  params:set("reverb_mix", amt * 0.5)
  params:set("reverb_size", 0.3 + amt * 0.6)
  params:set("gate_length", 0.5 + amt * 1.2)
end

-- SCRAMBLE: randomize drum pattern + melody notes in scale
local function macro_scramble()
  local p = patterns[current_pattern]
  local scale_notes = musicutil.generate_scale(
    params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 4)
  -- scramble melody notes
  for i = 1, p.length do
    if p.melody[i].on then
      p.melody[i].note = scale_notes[math.random(#scale_notes)]
      p.melody[i].vel = 0.4 + math.random() * 0.6
    end
  end
  -- scramble drums with probability
  for i = 1, p.length do
    if math.random() < 0.4 then p.kick[i] = not p.kick[i] end
    if math.random() < 0.5 then p.hat[i] = not p.hat[i] end
  end
  grid_dirty = true
end

-- DROP: kill melody, keep drums, filter down — for builds
local function macro_drop_toggle()
  if not drop_active then
    -- save and kill
    drop_active = true
    drop_saved.cutoff = params:get("cutoff")
    drop_saved.probability = params:get("probability")
    drop_saved.delay_mix = params:get("delay_mix")
    params:set("cutoff", 300)
    params:set("probability", 20)
    params:set("delay_mix", 0.6)
  else
    -- restore with a bump
    drop_active = false
    params:set("cutoff", drop_saved.cutoff or 2000)
    params:set("probability", drop_saved.probability or 100)
    params:set("delay_mix", drop_saved.delay_mix or 0.2)
  end
end

---------- ENCODERS & KEYS ----------

function enc(n, d)
  if n == 1 then
    current_page = util.clamp(current_page + (d > 0 and 1 or -1), 1, 6)

  elseif current_page == 1 then
    -- PLAY: E2 = tempo, E3 = MUTATE melody
    if n == 2 then
      params:delta("clock_tempo", d)
    elseif n == 3 then
      local p = patterns[current_pattern]
      local scale_notes = musicutil.generate_scale(
        params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 4)
      local steps_to_mutate = math.abs(d)
      for _ = 1, steps_to_mutate do
        local active = {}
        for i = 1, p.length do
          if p.melody[i].on then table.insert(active, i) end
        end
        if #active > 0 then
          local idx = active[math.random(#active)]
          local step = p.melody[idx]
          local drift = (d > 0 and 1 or -1) * math.random(1, 3)
          step.note = snap_to_scale(step.note + drift, scale_notes)
          if math.random() < 0.3 then
            step.vel = util.clamp(step.vel + (math.random() - 0.5) * 0.3, 0.3, 1.0)
          end
          -- occasionally mutate a drum hit too
          if math.random() < 0.15 then
            p.kick[idx] = not p.kick[idx]
          end
          if math.random() < 0.2 then
            p.hat[idx] = not p.hat[idx]
          end
        end
      end
      grid_dirty = true
    end

  elseif current_page == 2 then
    -- SOUND: E2 = DESTROY macro (bitcrush+res+feedback), E3 = OPEN macro (filter+fm+reverb)
    if n == 2 then
      macro_destroy_val = util.clamp(macro_destroy_val + d * 0.03, 0, 1)
      macro_destroy(macro_destroy_val)
    elseif n == 3 then
      macro_open_val = util.clamp(macro_open_val + d * 0.03, 0, 1)
      macro_open(macro_open_val)
    end

  elseif current_page == 3 then
    -- CHAOS: E2 = chaos amount, E3 = drum density (ghost fills)
    if n == 2 then
      params:delta("chaos_amt", d)
    elseif n == 3 then
      -- move kick+hat density together
      local kd = util.clamp(params:get("kick_density") + d * 0.03, 0, 1)
      local hd = util.clamp(params:get("hat_density") + d * 0.03, 0, 1)
      params:set("kick_density", kd)
      params:set("hat_density", hd)
      params:set("hat_variety", hd * 0.8)
    end

  elseif current_page == 4 then
    -- FX: E2 = delay time, E3 = delay feedback + bits together
    if n == 2 then
      params:delta("delay_time", d)
    elseif n == 3 then
      params:delta("delay_fb", d)
      local fb = params:get("delay_fb")
      params:set("delay_bits", util.clamp(16 - fb * 12, 4, 16))
    end

  elseif current_page == 5 then
    -- TAPE: E2 = speed, E3 = position scrub / chop select
    if n == 2 then
      if tape_mode == 3 then
        -- chop: E2 selects slice
        tape_chop_sel = util.clamp(tape_chop_sel + (d > 0 and 1 or -1), 1, tape_chop_slices)
        if tape_rec_length > 0 then
          local slice_len = tape_rec_length / tape_chop_slices
          local start = (tape_chop_sel - 1) * slice_len
          softcut.loop_start(2, start)
          softcut.loop_end(2, start + slice_len)
          softcut.position(2, start)
        end
      else
        -- normal: E2 = speed
        params:delta("tape_speed", d)
        if tape_playing then
          softcut.rate(2, params:get("tape_speed"))
        end
      end
    elseif n == 3 then
      if tape_mode == 3 then
        -- chop: E3 = number of slices
        tape_chop_slices = util.clamp(tape_chop_slices + (d > 0 and 1 or -1), 2, 16)
      else
        -- scrub position
        if tape_rec_length > 0 and tape_playing then
          local pos = tape_phase + d * 0.2
          pos = pos % tape_rec_length
          softcut.position(2, pos)
        end
      end
    end

  elseif current_page == 6 then
    -- MORPH: E2 = pattern morph, E3 = snapshot morph
    if n == 2 then
      local m = params:get("pattern_morph_amt")
      params:set("pattern_morph_amt", util.clamp(m + d * 0.03, 0, 1))
    elseif n == 3 then
      if morph_snapshot then
        local m = params:get("morph_amt")
        local new_m = util.clamp(m + d * 0.03, 0, 1)
        params:set("morph_amt", new_m)
        apply_morph(new_m)
      end
    end
  end

  screen_dirty = true
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_down = true
      k2_held_time = util.time()
    else
      k2_down = false
      local held = util.time() - k2_held_time
      if held > 0.5 then
        -- LONG PRESS: toggle autopilot
        if autopilot_on then stop_autopilot() else start_autopilot() end
      else
        -- SHORT PRESS: play/stop
        if playing then stop_sequencer() else start_sequencer() end
      end
    end

  elseif n == 3 and z == 1 then
    if current_page == 1 then
      -- SCRAMBLE: randomize pattern (melody notes + drum hits)
      save_snapshot()
      macro_scramble()

    elseif current_page == 2 then
      -- WAVE MORPH: cycle waveform + randomize FM ratio for surprise
      local w = params:get("waveform")
      params:set("waveform", (w % 4) + 1)
      params:set("fm_ratio", 0.5 + math.random() * 5.5)
      params:set("pw", 0.1 + math.random() * 0.8)

    elseif current_page == 3 then
      -- DROP/BUILD: toggle breakdown mode
      macro_drop_toggle()

    elseif current_page == 4 then
      -- TAPE STOP: crank bits down, slow delay, high feedback — then release
      if params:get("delay_bits") > 6 then
        save_snapshot()
        params:set("delay_bits", 3)
        params:set("delay_fb", 0.85)
        params:set("delay_time", 0.8)
        params:set("bit_depth", 4)
        params:set("sample_rate", 3000)
      else
        recall_snapshot()
      end

    elseif current_page == 5 then
      -- TAPE: cycle through REC / PLAY / CHOP
      if tape_mode == 1 then
        -- PLAY -> REC
        if tape_playing then tape_stop_play() end
        tape_start_rec()
      elseif tape_mode == 2 then
        -- REC -> PLAY
        tape_stop_rec()
        tape_start_play()
      elseif tape_mode == 3 then
        -- CHOP -> PLAY (reset to full loop)
        tape_stop_play()
        if tape_rec_length > 0 then
          softcut.loop_start(2, 0)
          softcut.loop_end(2, tape_rec_length)
        end
        tape_start_play()
      end

    elseif current_page == 6 then
      -- MORPH: capture snapshot for morphing
      capture_morph_snapshot()
      screen_dirty = true
    end
  end
  screen_dirty = true
end

---------- SCREEN ----------

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)

  if current_page == 1 then
    draw_play_page()
  elseif current_page == 2 then
    draw_sound_page()
  elseif current_page == 3 then
    draw_chaos_page()
  elseif current_page == 4 then
    draw_fx_page()
  elseif current_page == 5 then
    draw_tape_page()
  elseif current_page == 6 then
    draw_morph_page()
  end

  -- chaos particles overlay
  if params:get("chaos_amt") > 0.05 then
    for _, p in ipairs(particles) do
      screen.level(math.floor(p.bright * p.life / 12))
      screen.pixel(math.floor(p.x), math.floor(p.y))
      screen.fill()
    end
  end

  -- AUTOPILOT indicator — visible on ALL pages, top right, pulsing
  if autopilot_on then
    local pulse = math.floor(8 + math.sin(util.time() * 4) * 7)
    screen.level(pulse)
    screen.font_size(8)
    screen.move(88, 7)
    screen.text("AUTO")
    -- phase indicator bar
    screen.level(6)
    local phase_w = math.floor((autopilot_tick / (phase_lengths[autopilot_phase] or 12)) * 38)
    screen.rect(88, 8, phase_w, 2)
    screen.fill()
    -- phase name
    screen.level(3)
    screen.font_size(8)
    screen.move(88, 63)
    screen.text(PHASE_NAMES[autopilot_phase] or "")
  end

  screen.update()
end

function draw_play_page()
  local p = patterns[current_pattern]

  -- header
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("JAMSTL")
  screen.level(4)
  screen.move(44, 7)
  screen.text(playing and ">" or "||")
  screen.move(56, 7)
  screen.text(string.format("%d", params:get("clock_tempo")))
  screen.level(7)
  screen.move(108, 7)
  screen.text("P" .. current_pattern)

  -- step boxes
  for i = 1, p.length do
    local x = (i - 1) * 8
    local y = 12
    if i == current_step and playing then
      screen.level(15)
      screen.rect(x, y, 7, 14)
      screen.fill()
      if p.melody[i].on then
        screen.level(0)
        screen.font_size(6)
        screen.move(x + 1, y + 10)
        local name = musicutil.note_num_to_name(p.melody[i].note, false)
        screen.text(string.sub(name, 1, 2))
      end
    elseif p.melody[i].on then
      screen.level(8)
      screen.rect(x, y, 7, 14)
      screen.fill()
      screen.level(0)
      screen.font_size(6)
      screen.move(x + 1, y + 10)
      local name = musicutil.note_num_to_name(p.melody[i].note, false)
      screen.text(string.sub(name, 1, 2))
    else
      screen.level(2)
      screen.rect(x, y, 7, 14)
      screen.stroke()
    end
  end

  -- kick/hat pattern dots
  for i = 1, p.length do
    local x = (i - 1) * 8 + 3
    if p.kick[i] then
      screen.level((i == current_step and playing) and 15 or 8)
      screen.rect(x - 1, 29, 3, 3)
      screen.fill()
    end
    if p.hat[i] then
      screen.level((i == current_step and playing) and 15 or 5)
      screen.pixel(x, 34)
      screen.pixel(x - 1, 35)
      screen.pixel(x + 1, 35)
      screen.fill()
    end
  end

  -- bottom info
  screen.level(4)
  screen.font_size(8)
  screen.move(0, 44)
  screen.text(WAVE_NAMES[params:get("waveform")])
  screen.move(32, 44)
  screen.text(SCALE_DISPLAY[params:get("scale_type")])
  screen.move(64, 44)
  screen.text(autopilot_on and "AUTO" or "E3:mutate")

  -- chaos bar
  local chaos = params:get("chaos_amt")
  if chaos > 0 then
    screen.level(chaos_held and 15 or 6)
    screen.move(0, 52)
    screen.font_size(8)
    screen.text("chaos")
    screen.rect(36, 47, math.floor(chaos * 90), 4)
    screen.fill()
  end

  -- drop indicator
  if drop_active then
    screen.level(15)
    screen.move(0, 62)
    screen.text(">> DROP <<")
  end

  -- K3 hint
  screen.level(3)
  screen.move(90, 62)
  screen.text("K3:scram")
end

function draw_sound_page()
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("SOUND")
  screen.level(4)
  screen.move(48, 7)
  screen.text(WAVE_NAMES[params:get("waveform")])

  -- DESTROY macro bar
  screen.level(macro_destroy_val > 0.5 and 15 or 7)
  screen.move(0, 18)
  screen.text("DESTROY")
  screen.level(macro_destroy_val > 0.3 and 12 or 4)
  screen.rect(0, 20, math.floor(macro_destroy_val * 128), 4)
  screen.fill()

  -- OPEN macro bar
  screen.level(macro_open_val > 0.5 and 15 or 7)
  screen.move(0, 32)
  screen.text("OPEN")
  screen.level(macro_open_val > 0.3 and 12 or 4)
  screen.rect(0, 34, math.floor(macro_open_val * 128), 4)
  screen.fill()

  -- current values
  screen.level(4)
  screen.font_size(8)
  screen.move(0, 48)
  screen.text("bits:" .. string.format("%.0f", params:get("bit_depth")))
  screen.move(44, 48)
  screen.text("cut:" .. string.format("%.0f", params:get("cutoff")))
  screen.move(0, 58)
  screen.text("fm:" .. string.format("%.2f", params:get("fm_amt")))
  screen.move(44, 58)
  screen.text("res:" .. string.format("%.1f", params:get("res")))
  screen.move(64, y)
  screen.text("s" .. string.format("%.1f", params:get("env_sustain")))
  screen.move(96, y)
  screen.text("r" .. string.format("%.2f", params:get("env_release")))
end

function draw_chaos_page()
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("CHAOS")

  local chaos = params:get("chaos_amt")
  -- chaos amount bar
  screen.level(chaos > 0.5 and 15 or 8)
  screen.rect(48, 2, math.floor(chaos * 78), 5)
  screen.fill()
  screen.level(4)
  screen.move(100, 7)
  screen.text(string.format("%.2f", chaos))

  screen.level(7)
  screen.move(0, 20)
  screen.text("lfo1 " .. string.format("%.1f", params:get("lfo1_rate")) .. " hz")
  screen.move(0, 30)
  screen.text("lfo2 " .. string.format("%.1f", params:get("lfo2_rate")) .. " hz")

  -- lfo waveform visualization
  screen.level(6)
  for i = 0, 60 do
    local lfo1_y = 18 + math.sin(i * 0.2 * params:get("lfo1_rate")) * 3
    screen.pixel(66 + i, math.floor(lfo1_y))
  end
  screen.fill()
  screen.level(4)
  for i = 0, 60 do
    local t = i * 0.2 * params:get("lfo2_rate")
    local lfo2_y = 28 + (((t % (2*math.pi)) / math.pi) - 1) * 3
    screen.pixel(66 + i, math.floor(lfo2_y))
  end
  screen.fill()

  -- drum density
  screen.level(7)
  screen.move(0, 44)
  screen.text("E3:drums")
  local kd = params:get("kick_density")
  local hd = params:get("hat_density")
  screen.level(4)
  screen.move(60, 44)
  screen.text("k:" .. string.format("%.0f", kd * 100) .. "% h:" .. string.format("%.0f", hd * 100) .. "%")

  -- rungler register
  local rung = params:get("rungler_amt")
  if rung > 0.01 then
    screen.level(8)
    screen.move(0, 50)
    screen.text("RUNG")
    for i = 1, 8 do
      screen.level(rungler_register[i] == 1 and 15 or 2)
      screen.rect(28 + (i-1) * 7, 45, 5, 5)
      screen.fill()
    end
  end

  -- XOR drums mode
  local xm = params:get("xor_mode")
  if xm > 1 then
    screen.level(10)
    screen.move(90, 50)
    screen.text(XOR_NAMES[xm])
  end

  -- drop/build indicator
  screen.level(drop_active and 15 or 3)
  screen.move(0, 60)
  screen.text(drop_active and "K3:RELEASE!" or "K3:drop")

  if autopilot_on then
    screen.level(15)
    screen.move(80, 60)
    screen.text("AUTO")
  end
end

function draw_fx_page()
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("FX")

  screen.level(7)
  screen.move(0, 20)
  screen.text("delay " .. string.format("%.2f", params:get("delay_time")) .. "s")
  screen.move(0, 30)
  screen.text("fb    " .. string.format("%.2f", params:get("delay_fb")))
  screen.move(0, 40)
  screen.text("mix   " .. string.format("%.2f", params:get("delay_mix")))
  screen.move(0, 50)
  screen.text("bits  " .. string.format("%.0f", params:get("delay_bits")))

  screen.level(4)
  screen.move(80, 20)
  screen.text("reverb")
  screen.level(7)
  screen.move(80, 30)
  screen.text("mix " .. string.format("%.2f", params:get("reverb_mix")))
  screen.move(80, 40)
  screen.text("sz  " .. string.format("%.2f", params:get("reverb_size")))

  -- delay visualization
  screen.level(3)
  local dt = params:get("delay_time")
  local fb = params:get("delay_fb")
  for echo = 0, 4 do
    local x = 80 + echo * math.floor(dt * 30)
    local h = math.floor(12 * math.pow(fb, echo))
    if x < 128 and h > 0 then
      screen.rect(x, 58 - h, 2, h)
      screen.fill()
    end
  end
end

---------- TAPE PAGE ----------

function draw_tape_page()
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("TAPE")

  -- mode indicator
  screen.level(tape_recording and 15 or (tape_playing and 10 or 4))
  screen.move(40, 7)
  screen.text(TAPE_MODES[tape_mode])
  if tape_recording then
    screen.level(math.floor(util.time() * 4) % 2 == 0 and 15 or 0)
    screen.rect(34, 1, 4, 4)
    screen.fill()
  end

  -- speed
  screen.level(7)
  screen.move(0, 18)
  if tape_mode == 3 then
    screen.text("slice " .. tape_chop_sel .. "/" .. tape_chop_slices)
  else
    screen.text("spd " .. string.format("%.2fx", params:get("tape_speed")))
  end

  -- tape buffer visualization
  screen.level(2)
  screen.rect(0, 22, 128, 28)
  screen.stroke()

  -- recorded region
  if tape_rec_length > 0 then
    local rec_w = math.floor((tape_rec_length / TAPE_BUF_SEC) * 126)
    screen.level(3)
    screen.rect(1, 23, rec_w, 26)
    screen.fill()

    -- chop slices
    if tape_mode == 3 then
      local slice_w = rec_w / tape_chop_slices
      for i = 1, tape_chop_slices do
        local sx = 1 + (i - 1) * slice_w
        screen.level(i == tape_chop_sel and 12 or 1)
        screen.rect(math.floor(sx), 23, math.floor(slice_w) - 1, 26)
        screen.fill()
      end
    end

    -- playback position
    if tape_playing then
      local pos_x = 1 + (tape_phase / TAPE_BUF_SEC) * 126
      screen.level(15)
      screen.move(math.floor(pos_x), 22)
      screen.line(math.floor(pos_x), 50)
      screen.stroke()
    end
  else
    screen.level(3)
    screen.move(30, 38)
    screen.text("K3: start rec")
  end

  -- wow/flutter
  screen.level(5)
  screen.move(0, 58)
  screen.text("wow:" .. string.format("%.1f", params:get("tape_wow")))
  screen.move(50, 58)
  screen.text("flut:" .. string.format("%.1f", params:get("tape_flutter")))
  screen.move(100, 58)
  screen.text("mix:" .. string.format("%.1f", params:get("tape_mix")))
end

---------- MORPH PAGE ----------

function draw_morph_page()
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("MORPH")

  -- pattern morph
  local pm = params:get("pattern_morph_amt")
  screen.level(7)
  screen.move(0, 18)
  screen.text("E2: pattern " .. pattern_morph_a .. ">" .. pattern_morph_b)
  -- morph bar
  screen.level(3)
  screen.rect(0, 21, 100, 6)
  screen.stroke()
  screen.level(pm > 0.01 and 12 or 4)
  screen.rect(1, 22, math.floor(pm * 98), 4)
  screen.fill()
  screen.level(7)
  screen.move(104, 26)
  screen.text(string.format("%.0f%%", pm * 100))

  -- snapshot morph
  local sm = params:get("morph_amt")
  screen.level(7)
  screen.move(0, 36)
  screen.text("E3: snapshot")
  if morph_snapshot then
    screen.level(3)
    screen.rect(0, 39, 100, 6)
    screen.stroke()
    screen.level(sm > 0.01 and 10 or 4)
    screen.rect(1, 40, math.floor(sm * 98), 4)
    screen.fill()
    screen.level(7)
    screen.move(104, 44)
    screen.text(string.format("%.0f%%", sm * 100))
  else
    screen.level(3)
    screen.move(60, 44)
    screen.text("K3: capture")
  end

  -- cross-mod mini display
  screen.level(5)
  screen.move(0, 54)
  screen.text("XMOD")
  local xmod_params = {"xmod_lfo1_lfo2", "xmod_step_cutoff", "xmod_note_delay", "xmod_chaos_pan"}
  local xmod_labels = {"L>L", "S>C", "N>D", "C>P"}
  for i, pk in ipairs(xmod_params) do
    local x = 30 + (i - 1) * 25
    local val = params:get(pk)
    screen.level(val > 0.01 and 8 or 2)
    screen.rect(x, 52, math.floor(val * 20), 4)
    screen.fill()
    screen.level(4)
    screen.move(x, 62)
    screen.text(xmod_labels[i])
  end

  -- chain display
  if #chain > 0 then
    screen.level(5)
    screen.move(0, 62)
    screen.text("ch:")
    for i, entry in ipairs(chain) do
      if i > 8 then break end
      screen.level(chain_mode and i == chain_pos and 15 or 4)
      screen.move(16 + (i - 1) * 8, 62)
      screen.text(entry.pattern)
    end
  end
end

---------- AUTOPILOT ----------
-- internal algorithmic brain: evolves melody, timbre, drums, fx over time
-- cycles through phases: build → peak → deconstruct → minimal → rebuild

local function autopilot_evolve()
  autopilot_tick = autopilot_tick + 1
  local p = patterns[current_pattern]
  local scale_notes = musicutil.generate_scale(
    params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 4)
  local phase = autopilot_phase
  local progress = autopilot_tick / phase_lengths[phase]

  if phase == 1 then
    -- BUILD: gradually add density, open filter, increase chaos
    -- mutate 1-2 melody notes upward
    for _ = 1, math.random(1, 2) do
      local active = {}
      for i = 1, p.length do
        if p.melody[i].on then table.insert(active, i) end
      end
      if #active > 0 then
        local idx = active[math.random(#active)]
        p.melody[idx].note = snap_to_scale(p.melody[idx].note + math.random(1, 3), scale_notes)
      end
    end
    -- occasionally activate a new step
    if math.random() < 0.25 then
      local off = {}
      for i = 1, p.length do
        if not p.melody[i].on then table.insert(off, i) end
      end
      if #off > 0 then
        local idx = off[math.random(#off)]
        p.melody[idx].on = true
        p.melody[idx].note = scale_notes[math.random(#scale_notes)]
        p.melody[idx].vel = 0.5 + math.random() * 0.4
      end
    end
    -- add hat fills
    if math.random() < 0.3 then
      local i = math.random(1, p.length)
      p.hat[i] = true
    end
    -- open up sound
    params:set("cutoff", util.clamp(params:get("cutoff") + 200 + math.random(200), 200, 12000))
    params:set("chaos_amt", util.clamp(params:get("chaos_amt") + 0.03, 0, 0.7))
    params:set("hat_density", util.clamp(params:get("hat_density") + 0.04, 0, 0.7))
    -- BUILD: rungler rises, cross-mod step>cutoff begins
    params:set("rungler_amt", util.clamp(params:get("rungler_amt") + 0.03, 0, 0.5))
    params:set("xmod_step_cutoff", util.clamp(params:get("xmod_step_cutoff") + 0.02, 0, 0.4))

  elseif phase == 2 then
    -- PEAK: high energy, glitch moments, waveform surprises
    -- random timbre jolts
    if math.random() < 0.4 then
      params:set("bit_depth", 3 + math.random(10))
      params:set("fm_amt", math.random() * 1.2)
    end
    -- velocity accents
    for i = 1, p.length do
      if p.melody[i].on and math.random() < 0.2 then
        p.melody[i].vel = 0.8 + math.random() * 0.2
      end
    end
    -- drum mutation
    if math.random() < 0.3 then
      local i = math.random(1, p.length)
      p.kick[i] = not p.kick[i]
    end
    -- occasional waveform switch
    if math.random() < 0.15 then
      params:set("waveform", math.random(1, 4))
    end
    -- PEAK: rungler at max, XOR drums switch, cross-mod surges
    params:set("rungler_amt", util.clamp(params:get("rungler_amt") + 0.05, 0, 0.8))
    if math.random() < 0.2 then
      params:set("xor_mode", math.random(1, 5))
      update_xor_shadows()
    end
    if math.random() < 0.3 then
      params:set("xmod_lfo1_lfo2", math.random() * 0.6)
    end

  elseif phase == 3 then
    -- DECONSTRUCT: thin out, lower filter, increase delay
    -- remove notes
    if math.random() < 0.35 then
      local active = {}
      for i = 1, p.length do
        if p.melody[i].on then table.insert(active, i) end
      end
      if #active > 2 then  -- keep at least 2
        local idx = active[math.random(#active)]
        p.melody[idx].on = false
      end
    end
    -- close filter
    params:set("cutoff", util.clamp(params:get("cutoff") - 300, 300, 12000))
    -- more delay/reverb
    params:set("delay_mix", util.clamp(params:get("delay_mix") + 0.04, 0, 0.6))
    params:set("delay_fb", util.clamp(params:get("delay_fb") + 0.03, 0.2, 0.8))
    -- thin drums
    if math.random() < 0.25 then
      local i = math.random(1, p.length)
      p.hat[i] = false
    end
    params:set("hat_density", util.clamp(params:get("hat_density") - 0.05, 0, 0.7))
    -- DECONSTRUCT: tape effects rise, XOR to NAND
    params:set("tape_wow", util.clamp(params:get("tape_wow") + 0.05, 0, 0.6))
    params:set("tape_flutter", util.clamp(params:get("tape_flutter") + 0.03, 0, 0.4))
    if autopilot_tick == 2 and tape_rec_length > 0 then
      tape_start_play()
      params:set("tape_mix", 0.3)
    end
    if math.random() < 0.15 then
      params:set("xor_mode", 5)  -- NAND thins drums
    end

  elseif phase == 4 then
    -- MINIMAL/SPACE: sparse, deep, breathing room
    -- drift notes downward slowly
    for _ = 1, 1 do
      local active = {}
      for i = 1, p.length do
        if p.melody[i].on then table.insert(active, i) end
      end
      if #active > 0 then
        local idx = active[math.random(#active)]
        p.melody[idx].note = snap_to_scale(p.melody[idx].note - math.random(1, 2), scale_notes)
      end
    end
    -- clean up sound
    params:set("bit_depth", util.clamp(params:get("bit_depth") + 1, 8, 16))
    params:set("fm_amt", util.clamp(params:get("fm_amt") - 0.05, 0, 2))
    params:set("chaos_amt", util.clamp(params:get("chaos_amt") - 0.04, 0, 1))
    params:set("delay_mix", util.clamp(params:get("delay_mix") - 0.02, 0.05, 0.6))
    -- kick pattern simplify
    if math.random() < 0.2 then
      local i = math.random(1, p.length)
      if i % 4 ~= 1 then p.kick[i] = false end
    end
    -- SPACE: rungler fades, tape slows, cross-mod decays, XOR off
    params:set("rungler_amt", util.clamp(params:get("rungler_amt") - 0.05, 0, 1))
    params:set("xmod_step_cutoff", util.clamp(params:get("xmod_step_cutoff") - 0.03, 0, 1))
    params:set("xmod_lfo1_lfo2", util.clamp(params:get("xmod_lfo1_lfo2") - 0.04, 0, 1))
    params:set("tape_wow", util.clamp(params:get("tape_wow") - 0.03, 0, 1))
    params:set("tape_flutter", util.clamp(params:get("tape_flutter") - 0.02, 0, 1))
    if tape_playing then
      local sp = params:get("tape_speed")
      params:set("tape_speed", util.clamp(sp * 0.9, 0.1, 2))
      softcut.rate(2, params:get("tape_speed"))
    end
    if autopilot_tick > 6 then
      params:set("xor_mode", 1)  -- XOR off
    end
  end

  -- phase transition
  if autopilot_tick >= phase_lengths[phase] then
    autopilot_tick = 0
    autopilot_phase = (autopilot_phase % 4) + 1
    -- randomize phase length for next cycle (keep it unpredictable)
    phase_lengths[autopilot_phase] = phase_lengths[autopilot_phase] + math.random(-3, 3)
    phase_lengths[autopilot_phase] = util.clamp(phase_lengths[autopilot_phase], 6, 20)
  end

  grid_dirty = true
  screen_dirty = true
end

local function start_autopilot()
  autopilot_on = true
  autopilot_tick = 0
  autopilot_phase = 1
  autopilot_clock_id = clock.run(function()
    while autopilot_on do
      clock.sync(2)  -- evolve every 2 beats
      if autopilot_on and playing then
        autopilot_evolve()
      end
    end
  end)
end

local function stop_autopilot()
  autopilot_on = false
  if autopilot_clock_id then
    clock.cancel(autopilot_clock_id)
    autopilot_clock_id = nil
  end
end

---------- OP-XY CC SYNC ----------
-- sends CC for key params so OP-XY display reflects state
-- CC mapping: 1=cutoff, 2=res, 3=chaos, 4=bitdepth, 5=gate, 7=volume(hat_density)

local last_opxy_cc = {}

local function opxy_sync_params()
  if not opxy_device or params:get("opxy_device") <= 1 then return end
  local opxy_mel_ch = params:get("opxy_melody_ch")

  -- cutoff: 20-18000 -> 0-127
  local cut_cc = math.floor(util.clamp((params:get("cutoff") - 20) / 17980 * 127, 0, 127))
  if cut_cc ~= last_opxy_cc[1] then
    opxy_cc(74, cut_cc, opxy_mel_ch)  -- CC74 = brightness (filter cutoff standard)
    last_opxy_cc[1] = cut_cc
  end

  -- chaos: 0-1 -> 0-127
  local chaos_cc = math.floor(params:get("chaos_amt") * 127)
  if chaos_cc ~= last_opxy_cc[3] then
    opxy_cc(1, chaos_cc, opxy_mel_ch)  -- CC1 = mod wheel
    last_opxy_cc[3] = chaos_cc
  end

  -- bit depth: 1-16 -> 127-0 (inverted: low bits = high CC)
  local bit_cc = math.floor((1 - (params:get("bit_depth") - 1) / 15) * 127)
  if bit_cc ~= last_opxy_cc[4] then
    opxy_cc(18, bit_cc, opxy_mel_ch)  -- CC18
    last_opxy_cc[4] = bit_cc
  end

  -- gate length: 0.1-2.0 -> 0-127
  local gate_cc = math.floor(util.clamp((params:get("gate_length") - 0.1) / 1.9 * 127, 0, 127))
  if gate_cc ~= last_opxy_cc[5] then
    opxy_cc(73, gate_cc, opxy_mel_ch)  -- CC73 = attack time (close enough)
    last_opxy_cc[5] = gate_cc
  end
end

---------- MIDI IN ----------

local function midi_event(data)
  local msg = midi.to_msg(data)
  if not msg then return end
  local ch = params:get("midi_in_ch")
  if ch > 0 and msg.ch ~= ch then return end

  if msg.type == "note_on" and msg.vel > 0 then
    play_live_note(msg.note, msg.vel / 127)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    stop_live_note(msg.note)
  elseif msg.type == "cc" then
    -- CC input: map common CCs to params
    if msg.cc == 74 then  -- filter cutoff
      params:set("cutoff", 20 + (msg.val / 127) * 17980)
    elseif msg.cc == 1 then  -- mod wheel -> chaos
      params:set("chaos_amt", msg.val / 127)
    elseif msg.cc == 71 then  -- resonance
      params:set("res", (msg.val / 127) * 3.5)
    elseif msg.cc == 73 then  -- attack -> gate length
      params:set("gate_length", 0.1 + (msg.val / 127) * 1.9)
    elseif msg.cc == 18 then  -- CC18 -> bit depth
      params:set("bit_depth", 16 - (msg.val / 127) * 15)
    end
  end
end

---------- INIT ----------

function init()
  -- init patterns: always start with fresh randomized patterns
  init_default_patterns()
  randomize_all_patterns()

  -- MIDI
  midi_out_device = midi.connect(1)
  midi_in_device = midi.connect(1)
  midi_in_device.event = midi_event

  -- ===== PARAMS =====

  params:add_separator("JAMSTL")

  -- sequence
  params:add_group("SEQUENCE", 10)
  params:add_number("root_note", "root note", 24, 96, 60)
  params:set_action("root_note", function() update_keyboard() end)
  params:add_option("scale_type", "scale", SCALE_DISPLAY, 1)
  params:set_action("scale_type", function() update_keyboard() end)
  params:add_number("swing", "swing", 0, 80, 0)
  params:add_option("waveform", "waveform", WAVE_NAMES, 1)
  params:set_action("waveform", function(x) engine.wave(x - 1) end)
  params:add_number("pattern_length", "pattern length", 1, 16, 16)
  params:set_action("pattern_length", function(x)
    patterns[current_pattern].length = x
  end)
  params:add_control("gate_length", "gate length",
    controlspec.new(0.1, 2.0, 'lin', 0.01, 1.0, "x"))
  params:add_number("probability", "probability", 0, 100, 100)
  params:add_number("octave_shift", "octave shift", -2, 2, 0)
  params:add_control("note_drift", "note drift",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("pan", "pan",
    controlspec.new(-1, 1, 'lin', 0.01, 0))
  params:set_action("pan", function(x) engine.pan(x) end)

  -- oscillator
  params:add_group("OSCILLATOR", 6)
  params:add_control("cutoff", "cutoff",
    controlspec.new(20, 18000, 'exp', 0, 2000, "hz"))
  params:set_action("cutoff", function(x) engine.cutoff(x) end)
  params:add_control("res", "resonance",
    controlspec.new(0, 3.5, 'lin', 0.01, 0.3))
  params:set_action("res", function(x) engine.res(x) end)
  params:add_control("fm_amt", "fm amount",
    controlspec.new(0, 2, 'lin', 0.01, 0))
  params:set_action("fm_amt", function(x) engine.fm_amt(x) end)
  params:add_control("fm_ratio", "fm ratio",
    controlspec.new(0.25, 8, 'exp', 0.01, 2))
  params:set_action("fm_ratio", function(x) engine.fm_ratio(x) end)
  params:add_control("sub_amt", "sub level",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:set_action("sub_amt", function(x) engine.sub_amt(x) end)
  params:add_control("noise_amt", "noise level",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:set_action("noise_amt", function(x) engine.noise_amt(x) end)

  -- bitcrush
  params:add_group("BITCRUSH", 3)
  params:add_control("bit_depth", "bit depth",
    controlspec.new(1, 16, 'lin', 0.5, 12))
  params:set_action("bit_depth", function(x) engine.bits(x) end)
  params:add_control("sample_rate", "sample rate",
    controlspec.new(500, 48000, 'exp', 100, 26000, "hz"))
  params:set_action("sample_rate", function(x) engine.sample_rate(x) end)
  params:add_control("pw", "pulse width",
    controlspec.new(0.01, 0.99, 'lin', 0.01, 0.5))
  params:set_action("pw", function(x) engine.pw(x) end)

  -- envelope
  params:add_group("ENVELOPE", 4)
  params:add_control("env_attack", "attack",
    controlspec.new(0.001, 2, 'exp', 0, 0.005, "s"))
  params:set_action("env_attack", function(x) engine.attack(x) end)
  params:add_control("env_decay", "decay",
    controlspec.new(0.01, 2, 'exp', 0, 0.15, "s"))
  params:set_action("env_decay", function(x) engine.decay(x) end)
  params:add_control("env_sustain", "sustain",
    controlspec.new(0, 1, 'lin', 0.01, 0.6))
  params:set_action("env_sustain", function(x) engine.sustain_level(x) end)
  params:add_control("env_release", "release",
    controlspec.new(0.01, 5, 'exp', 0, 0.3, "s"))
  params:set_action("env_release", function(x) engine.release(x) end)

  -- chaos
  params:add_group("CHAOS", 5)
  params:add_control("chaos_amt", "chaos",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:set_action("chaos_amt", function(x) engine.chaos(x) end)
  params:add_control("lfo1_rate", "lfo1 rate",
    controlspec.new(0.01, 20, 'exp', 0.01, 2, "hz"))
  params:set_action("lfo1_rate", function(x) engine.lfo1_rate(x) end)
  params:add_control("lfo2_rate", "lfo2 rate",
    controlspec.new(0.01, 20, 'exp', 0.01, 0.3, "hz"))
  params:set_action("lfo2_rate", function(x) engine.lfo2_rate(x) end)
  params:add_control("rungler_amt", "rungler",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_option("rungler_clock_div", "rungler div", {"1", "2", "4", "8"}, 1)

  -- drums
  params:add_group("DRUMS", 11)
  params:add_control("kick_tune", "kick tune",
    controlspec.new(30, 200, 'exp', 1, 60, "hz"))
  params:set_action("kick_tune", function(x) engine.kick_tune(x) end)
  params:add_control("kick_decay", "kick decay",
    controlspec.new(0.05, 1.0, 'exp', 0.01, 0.3, "s"))
  params:set_action("kick_decay", function(x) engine.kick_decay(x) end)
  params:add_control("hat_decay", "hat decay",
    controlspec.new(0.01, 0.5, 'exp', 0.01, 0.08, "s"))
  params:set_action("hat_decay", function(x) engine.hat_decay(x) end)
  params:add_number("kick_prob", "kick probability", 0, 100, 100)
  params:add_number("hat_prob", "hat probability", 0, 100, 100)
  params:add_control("kick_density", "kick ghost density",
    controlspec.new(0, 1, 'lin', 0.01, 0.15))
  params:add_control("hat_density", "hat ghost density",
    controlspec.new(0, 1, 'lin', 0.01, 0.25))
  params:add_control("hat_variety", "hat variety",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:add_option("xor_mode", "XOR drums", XOR_NAMES, 1)
  params:set_action("xor_mode", function() update_xor_shadows() end)
  params:add_number("xor_kick_fills", "XOR kick fills", 0, 16, 5)
  params:set_action("xor_kick_fills", function() update_xor_shadows() end)
  params:add_number("xor_hat_fills", "XOR hat fills", 0, 16, 7)
  params:set_action("xor_hat_fills", function() update_xor_shadows() end)

  -- fx
  params:add_group("FX", 6)
  params:add_control("delay_time", "delay time",
    controlspec.new(0.01, 1.5, 'exp', 0.01, 0.3, "s"))
  params:set_action("delay_time", function(x) engine.delay_time(x) end)
  params:add_control("delay_fb", "delay feedback",
    controlspec.new(0, 0.95, 'lin', 0.01, 0.4))
  params:set_action("delay_fb", function(x) engine.delay_fb(x) end)
  params:add_control("delay_mix", "delay mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.2))
  params:set_action("delay_mix", function(x) engine.delay_mix(x) end)
  params:add_control("delay_bits", "delay bits",
    controlspec.new(1, 16, 'lin', 1, 12))
  params:set_action("delay_bits", function(x) engine.delay_bits(x) end)
  params:add_control("reverb_mix", "reverb mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.15))
  params:set_action("reverb_mix", function(x) engine.reverb_mix(x) end)
  params:add_control("reverb_size", "reverb size",
    controlspec.new(0, 1, 'lin', 0.01, 0.7))
  params:set_action("reverb_size", function(x) engine.reverb_size(x) end)

  -- midi
  params:add_group("MIDI", 7)
  params:add_number("midi_out_ch", "midi out ch", 0, 16, 0)
  params:add_number("midi_in_ch", "midi in ch", 0, 16, 0)

  -- OP-XY dedicated output
  local midi_devices = {"none"}
  for i = 1, #midi.vports do
    local name = midi.vports[i].name or ("port " .. i)
    table.insert(midi_devices, i .. ": " .. name)
  end
  params:add_option("opxy_device", "OP-XY device", midi_devices, 1)
  params:set_action("opxy_device", function(x)
    if x > 1 then
      opxy_device = midi.connect(x - 1)
    else
      opxy_device = nil
    end
  end)
  params:add_number("opxy_melody_ch", "OP-XY melody ch", 1, 16, 1)
  params:add_number("opxy_drum_ch", "OP-XY drum ch", 1, 16, 10)

  -- tape
  params:add_group("TAPE", 4)
  params:add_control("tape_speed", "tape speed",
    controlspec.new(-2, 2, 'lin', 0.01, 1, "x"))
  params:add_control("tape_wow", "tape wow",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("tape_flutter", "tape flutter",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("tape_mix", "tape mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))

  -- morph
  params:add_group("MORPH", 2)
  params:add_control("pattern_morph_amt", "pattern morph",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("morph_amt", "snapshot morph",
    controlspec.new(0, 1, 'lin', 0.01, 0))

  -- cross-mod
  params:add_group("CROSS-MOD", 4)
  params:add_control("xmod_lfo1_lfo2", "LFO1>LFO2",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("xmod_step_cutoff", "STEP>CUT",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("xmod_note_delay", "NOTE>DLY",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:add_control("xmod_chaos_pan", "CHAOS>PAN",
    controlspec.new(0, 1, 'lin', 0.01, 0))

  -- save/load slots
  params:add_group("SAVE/LOAD", 3)
  params:add_option("save_slot", "save to slot", {"1","2","3","4","5","6","7","8"}, 1)
  params:add_trigger("save_go", ">> SAVE <<")
  params:set_action("save_go", function()
    save_to_slot(params:get("save_slot"))
  end)
  params:add_trigger("load_go", ">> LOAD <<")
  params:set_action("load_go", function()
    local slot = params:get("save_slot")
    if load_from_slot(slot) then
      grid_dirty = true
      screen_dirty = true
    end
  end)

  -- init keyboard
  update_keyboard()

  -- init xor shadows
  update_xor_shadows()

  -- SOFTCUT: tape setup
  audio.level_eng_cut(1)  -- route engine output to softcut input
  softcut.buffer_clear()
  -- voice 1: recorder
  softcut.enable(1, 1)
  softcut.buffer(1, 1)
  softcut.level(1, 0)
  softcut.rate(1, 1)
  softcut.loop(1, 0)
  softcut.position(1, 0)
  softcut.rec_level(1, 1)
  softcut.pre_level(1, 0)
  softcut.level_input_cut(1, 1, 1)
  softcut.level_input_cut(2, 1, 1)
  softcut.rec(1, 0)
  softcut.play(1, 0)
  softcut.fade_time(1, 0.01)
  -- voice 2: playback
  softcut.enable(2, 1)
  softcut.buffer(2, 1)
  softcut.level(2, 1)
  softcut.rate(2, 1)
  softcut.loop(2, 1)
  softcut.loop_start(2, 0)
  softcut.loop_end(2, TAPE_BUF_SEC)
  softcut.position(2, 0)
  softcut.rec(2, 0)
  softcut.play(2, 0)
  softcut.fade_time(2, 0.01)
  softcut.rate_slew_time(2, 0.1)
  softcut.level_slew_time(2, 0.05)
  -- phase polling
  softcut.phase_quant(2, 0.05)
  softcut.event_phase(function(voice, pos)
    if voice == 2 then tape_phase = pos end
  end)
  softcut.poll_start_phase()

  -- screen refresh metro
  screen_metro = metro.init()
  screen_metro.event = function()
    update_particles()
    opxy_sync_params()
    -- tape wow/flutter
    if tape_playing then
      local wow = params:get("tape_wow")
      local flutter = params:get("tape_flutter")
      local speed = params:get("tape_speed")
      if wow > 0.01 or flutter > 0.01 then
        local wow_mod = math.sin(util.time() * 0.5) * wow * 0.15
        local flutter_mod = math.sin(util.time() * 12) * flutter * 0.05
        softcut.rate(2, speed + wow_mod + flutter_mod)
      end
      softcut.level(2, params:get("tape_mix"))
    end
    -- continuous cross-mod (LFO1>LFO2 and CHAOS>PAN)
    if params:get("xmod_lfo1_lfo2") > 0.01 or params:get("xmod_chaos_pan") > 0.01 then
      apply_cross_mod()
    end
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  screen_metro.time = 1/15
  screen_metro:start()

  -- grid refresh clock
  grid_clock_id = clock.run(function()
    while true do
      clock.sleep(1/30)
      if grid_dirty and g.device then
        grid_redraw()
        grid_dirty = false
      end
    end
  end)

  -- initial param push to engine
  params:bang()
end

---------- CLEANUP ----------

function cleanup()
  stop_autopilot()
  if seq_clock_id then clock.cancel(seq_clock_id) end
  if grid_clock_id then clock.cancel(grid_clock_id) end
  if screen_metro then screen_metro:stop() end
  if midi_out_device then
    for note = 0, 127 do
      midi_out_device:note_off(note, 0, 1)
    end
  end
  -- OP-XY cleanup
  if opxy_device then
    for ch = 1, 16 do
      for note = 0, 127 do
        opxy_device:note_off(note, 0, ch)
      end
    end
  end
  -- softcut cleanup
  softcut.rec(1, 0)
  softcut.play(1, 0)
  softcut.play(2, 0)
  softcut.buffer_clear()
  softcut.poll_stop_phase()
end
