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
local PAGES = {"PLAY", "SOUND", "CHAOS", "FX"}
local WAVE_NAMES = {"saw", "pulse", "tri", "noise"}
local SCALE_NAMES = {"major", "natural_minor", "dorian", "phrygian",
  "mixolydian", "pentatonic_maj", "pentatonic_min", "chromatic"}
local SCALE_DISPLAY = {"MAJ", "MIN", "DOR", "PHR", "MIX", "PNT", "PNm", "CHR"}

---------- STATE ----------

local playing = false
local current_step = 0
local current_pattern = 1
local current_page = 1
local held_step = 0
local euclid_fills = 8
local euclid_offset = 0
local euclid_track = 1
local chaos_held = false

local patterns = {}

local g = grid.connect()
local grid_dirty = true

local keyboard_notes = {}

local midi_out_device
local midi_in_device

local screen_dirty = true
local screen_metro
local particles = {}

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

local function init_default_patterns()
  for i = 1, NUM_PATTERNS do
    patterns[i] = new_pattern()
  end
  local notes = {60, 63, 65, 67, 70, 72, 70, 67, 65, 63, 60, 63, 67, 70, 72, 67}
  local on =    {1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0}
  for i = 1, 16 do
    patterns[1].melody[i].on = on[i] == 1
    patterns[1].melody[i].note = notes[i]
    patterns[1].melody[i].vel = (i % 4 == 1) and 1.0 or 0.7
    patterns[1].melody[i].chaos = (i > 12) and 0.4 or 0
  end
  patterns[1].kick = {true,false,false,false,true,false,false,false,
                      true,false,false,false,true,false,false,false}
  patterns[1].hat =  {false,true,false,true,false,true,false,true,
                      false,true,false,true,false,true,false,true}
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

---------- PARTICLES ----------

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

---------- NOTE PLAYBACK ----------

local function play_note(note, vel, gate_time)
  local freq = musicutil.note_num_to_freq(note)
  engine.note_on(note, freq, vel)
  if midi_out_device and params:get("midi_out_ch") > 0 then
    local ch = params:get("midi_out_ch")
    midi_out_device:note_on(note, math.floor(vel * 127), ch)
  end
  clock.run(function()
    clock.sleep(gate_time)
    engine.note_off(note)
    if midi_out_device and params:get("midi_out_ch") > 0 then
      midi_out_device:note_off(note, 0, params:get("midi_out_ch"))
    end
  end)
end

local function play_live_note(note, vel)
  local freq = musicutil.note_num_to_freq(note)
  engine.note_on(note, freq, vel)
  if midi_out_device and params:get("midi_out_ch") > 0 then
    midi_out_device:note_on(note, math.floor(vel * 127), params:get("midi_out_ch"))
  end
end

local function stop_live_note(note)
  engine.note_off(note)
  if midi_out_device and params:get("midi_out_ch") > 0 then
    midi_out_device:note_off(note, 0, params:get("midi_out_ch"))
  end
end

---------- SEQUENCER ----------

local function advance_step()
  local p = patterns[current_pattern]
  current_step = (current_step % p.length) + 1

  local beat_dur = clock.get_beat_sec() / 4
  local swing = params:get("swing") / 100

  local step = p.melody[current_step]
  if step.on then
    local step_chaos = step.chaos
    if step_chaos > 0 then
      engine.chaos(params:get("chaos_amt") + step_chaos)
    end
    if math.random(100) <= step.prob then
      local note = step.note
      local vel = step.vel
      if step_chaos > 0 and math.random() < step_chaos * 0.3 then
        local scale_notes = musicutil.generate_scale(
          params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 4)
        note = snap_to_scale(note + math.random(-3, 3), scale_notes)
      end
      if step_chaos > 0 then
        vel = util.clamp(vel + (math.random() - 0.5) * step_chaos * 0.3, 0.1, 1.0)
      end
      play_note(note, vel, beat_dur * step.gate * 2)
    end
    if step_chaos > 0 then
      engine.chaos(params:get("chaos_amt"))
    end
  end

  if p.kick[current_step] then
    local vel = (current_step % 4 == 1) and 1.0 or 0.75
    engine.kick(vel)
    if midi_out_device and params:get("midi_out_ch") > 0 then
      midi_out_device:note_on(36, math.floor(vel * 127), params:get("midi_out_ch"))
      clock.run(function()
        clock.sleep(0.05)
        midi_out_device:note_off(36, 0, params:get("midi_out_ch"))
      end)
    end
  end

  if p.hat[current_step] then
    local vel = 0.4 + math.random() * 0.2
    engine.hat(vel)
    if midi_out_device and params:get("midi_out_ch") > 0 then
      midi_out_device:note_on(42, math.floor(vel * 127), params:get("midi_out_ch"))
      clock.run(function()
        clock.sleep(0.05)
        midi_out_device:note_off(42, 0, params:get("midi_out_ch"))
      end)
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

---------- EUCLIDEAN ----------

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
    if y == 1 and x <= p.length then
      if held_step == 0 then
        p.melody[x].on = not p.melody[x].on
      end
      held_step = x

    elseif y == 2 and x <= p.length then
      p.kick[x] = not p.kick[x]

    elseif y == 3 and x <= p.length then
      p.hat[x] = not p.hat[x]

    elseif y == 4 and x <= p.length then
      local c = p.melody[x].chaos
      if c < 0.1 then c = 0.3
      elseif c < 0.4 then c = 0.6
      elseif c < 0.7 then c = 1.0
      else c = 0 end
      p.melody[x].chaos = c

    elseif y >= 5 and y <= 7 then
      if keyboard_notes[y] and keyboard_notes[y][x] then
        local note = keyboard_notes[y][x]
        if held_step > 0 then
          p.melody[held_step].note = note
          p.melody[held_step].on = true
        else
          play_live_note(note, 0.8)
        end
      end

    elseif y == 8 then
      if x >= 1 and x <= 8 then
        current_pattern = x
        update_keyboard()
      elseif x == 10 then
        euclid_track = (euclid_track % 3) + 1
      elseif x == 11 then
        euclid_fills = math.max(0, euclid_fills - 1)
        apply_euclidean()
      elseif x == 12 then
        euclid_fills = math.min(16, euclid_fills + 1)
        apply_euclidean()
      elseif x == 13 then
        euclid_offset = (euclid_offset + 1) % 16
        apply_euclidean()
      elseif x == 14 then
        local scale_notes = musicutil.generate_scale(
          params:get("root_note"), SCALE_NAMES[params:get("scale_type")], 3)
        for i = 1, p.length do
          if p.melody[i].on then
            p.melody[i].note = scale_notes[math.random(#scale_notes)]
          end
        end
      elseif x == 15 then
        if playing then stop_sequencer() else start_sequencer() end
      elseif x == 16 then
        chaos_engage()
      end
    end

  else
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
    end
  end

  grid_dirty = true
  screen_dirty = true
end

local function grid_redraw()
  g:all(0)
  local p = patterns[current_pattern]

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

  for x = 1, p.length do
    local b = 2
    if p.kick[x] then b = (x == current_step and playing) and 15 or 10 end
    if x == current_step and playing and p.kick[x] then b = 15 end
    g:led(x, 2, b)
  end

  for x = 1, p.length do
    local b = 2
    if p.hat[x] then b = (x == current_step and playing) and 15 or 7 end
    g:led(x, 3, b)
  end

  for x = 1, p.length do
    local c = p.melody[x].chaos
    local b = 0
    if c > 0.8 then b = 15
    elseif c > 0.5 then b = 10
    elseif c > 0.1 then b = 5
    else b = 1 end
    g:led(x, 4, b)
  end

  for row = 5, 7 do
    if keyboard_notes[row] then
      for col = 1, 16 do
        if keyboard_notes[row][col] then
          local note = keyboard_notes[row][col]
          local b = 3
          if note % 12 == params:get("root_note") % 12 then
            b = 8
          end
          if held_step > 0 and p.melody[held_step].note == note then
            b = 15
          end
          g:led(col, row, b)
        end
      end
    end
  end

  for x = 1, 8 do
    g:led(x, 8, x == current_pattern and 15 or 3)
  end
  g:led(10, 8, ({8, 10, 6})[euclid_track])
  g:led(11, 8, 4)
  g:led(12, 8, 4)
  g:led(13, 8, 4)
  g:led(14, 8, 6)
  g:led(15, 8, playing and 15 or 4)
  g:led(16, 8, chaos_held and 15 or 8)

  g:refresh()
end

---------- ENCODERS & KEYS ----------

function enc(n, d)
  if n == 1 then
    current_page = util.clamp(current_page + (d > 0 and 1 or -1), 1, 4)

  elseif current_page == 1 then
    if n == 2 then
      params:delta("clock_tempo", d)
    elseif n == 3 then
      params:delta("swing", d)
    end

  elseif current_page == 2 then
    if n == 2 then
      params:delta("cutoff", d)
    elseif n == 3 then
      params:delta("res", d)
    end

  elseif current_page == 3 then
    if n == 2 then
      params:delta("chaos_amt", d)
    elseif n == 3 then
      params:delta("lfo1_rate", d)
    end

  elseif current_page == 4 then
    if n == 2 then
      params:delta("delay_time", d)
    elseif n == 3 then
      params:delta("delay_mix", d)
    end
  end

  screen_dirty = true
end

function key(n, z)
  if n == 2 and z == 1 then
    if playing then stop_sequencer() else start_sequencer() end
  elseif n == 3 and z == 1 then
    if current_page == 1 then
      local w = params:get("waveform")
      params:set("waveform", (w % 4) + 1)
    elseif current_page == 2 then
      local s = params:get("scale_type")
      params:set("scale_type", (s % #SCALE_NAMES) + 1)
    elseif current_page == 3 then
      apply_euclidean()
    elseif current_page == 4 then
      local b = params:get("delay_bits")
      if b > 10 then params:set("delay_bits", 6)
      else params:set("delay_bits", 16) end
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
  end

  if params:get("chaos_amt") > 0.05 then
    for _, p in ipairs(particles) do
      screen.level(math.floor(p.bright * p.life / 12))
      screen.pixel(math.floor(p.x), math.floor(p.y))
      screen.fill()
    end
  end

  screen.update()
end

function draw_play_page()
  local p = patterns[current_pattern]

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

  screen.level(4)
  screen.font_size(8)
  screen.move(0, 44)
  screen.text(WAVE_NAMES[params:get("waveform")])
  screen.move(32, 44)
  screen.text(SCALE_DISPLAY[params:get("scale_type")])
  screen.move(56, 44)
  screen.text("sw:" .. params:get("swing"))

  local chaos = params:get("chaos_amt")
  if chaos > 0 then
    screen.level(chaos_held and 15 or 6)
    screen.move(0, 52)
    screen.font_size(8)
    screen.text("chaos")
    screen.rect(36, 47, math.floor(chaos * 90), 4)
    screen.fill()
  end
end

function draw_sound_page()
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 7)
  screen.text("SOUND")
  screen.level(4)
  screen.move(48, 7)
  screen.text(WAVE_NAMES[params:get("waveform")])

  screen.level(7)
  screen.font_size(8)
  local y = 18
  screen.move(0, y)
  screen.text("cut " .. string.format("%.0f", params:get("cutoff")))
  screen.move(70, y)
  screen.text("res " .. string.format("%.2f", params:get("res")))

  y = 28
  screen.move(0, y)
  screen.text("bits " .. string.format("%.0f", params:get("bit_depth")))
  screen.move(70, y)
  screen.text("sr " .. string.format("%.0f", params:get("sample_rate") / 1000) .. "k")

  y = 38
  screen.move(0, y)
  screen.text("fm " .. string.format("%.2f", params:get("fm_amt")))
  screen.move(70, y)
  screen.text("rat " .. string.format("%.1f", params:get("fm_ratio")))

  y = 48
  screen.move(0, y)
  screen.text("sub " .. string.format("%.2f", params:get("sub_amt")))
  screen.move(70, y)
  screen.text("nse " .. string.format("%.2f", params:get("noise_amt")))

  y = 58
  screen.level(4)
  screen.move(0, y)
  screen.text("a" .. string.format("%.2f", params:get("env_attack")))
  screen.move(32, y)
  screen.text("d" .. string.format("%.2f", params:get("env_decay")))
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

  screen.level(7)
  screen.move(0, 44)
  local track_names = {"melody", "kick", "hat"}
  screen.text("euclid: " .. track_names[euclid_track])
  screen.move(0, 54)
  screen.text("fills:" .. euclid_fills .. " off:" .. euclid_offset)

  screen.level(4)
  screen.move(0, 63)
  screen.text("K3: apply euclidean")
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
  end
end

---------- INIT ----------

function init()
  init_default_patterns()

  midi_out_device = midi.connect(1)
  midi_in_device = midi.connect(1)
  midi_in_device.event = midi_event

  params:add_separator("JAMSTL")

  params:add_group("SEQUENCE", 5)
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

  params:add_group("CHAOS", 3)
  params:add_control("chaos_amt", "chaos",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:set_action("chaos_amt", function(x) engine.chaos(x) end)
  params:add_control("lfo1_rate", "lfo1 rate",
    controlspec.new(0.01, 20, 'exp', 0.01, 2, "hz"))
  params:set_action("lfo1_rate", function(x) engine.lfo1_rate(x) end)
  params:add_control("lfo2_rate", "lfo2 rate",
    controlspec.new(0.01, 20, 'exp', 0.01, 0.3, "hz"))
  params:set_action("lfo2_rate", function(x) engine.lfo2_rate(x) end)

  params:add_group("DRUMS", 3)
  params:add_control("kick_tune", "kick tune",
    controlspec.new(30, 200, 'exp', 1, 60, "hz"))
  params:set_action("kick_tune", function(x) engine.kick_tune(x) end)
  params:add_control("kick_decay", "kick decay",
    controlspec.new(0.05, 1.0, 'exp', 0.01, 0.3, "s"))
  params:set_action("kick_decay", function(x) engine.kick_decay(x) end)
  params:add_control("hat_decay", "hat decay",
    controlspec.new(0.01, 0.5, 'exp', 0.01, 0.08, "s"))
  params:set_action("hat_decay", function(x) engine.hat_decay(x) end)

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

  params:add_group("MIDI", 2)
  params:add_number("midi_out_ch", "midi out ch", 0, 16, 0)
  params:add_number("midi_in_ch", "midi in ch", 0, 16, 0)

  update_keyboard()

  screen_metro = metro.init()
  screen_metro.event = function()
    update_particles()
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  screen_metro.time = 1/15
  screen_metro:start()

  grid_clock_id = clock.run(function()
    while true do
      clock.sleep(1/30)
      if grid_dirty and g.device then
        grid_redraw()
        grid_dirty = false
      end
    end
  end)

  params:bang()
end

---------- CLEANUP ----------

function cleanup()
  if seq_clock_id then clock.cancel(seq_clock_id) end
  if grid_clock_id then clock.cancel(grid_clock_id) end
  if screen_metro then screen_metro:stop() end
  if midi_out_device then
    for note = 0, 127 do
      midi_out_device:note_off(note, 0, 1)
    end
  end
end
