// Engine_Jamstl
// A digital chaos synthesizer inspired by Bastl Instruments
//
// Kastl DNA:  raw digital oscillators, FM cross-mod
// Bitranger:  bitcrushing, sample rate reduction
// Softpop:    chaos self-modulation, LFO feedback
// Cinnamon:   resonant filter with self-oscillation
// Tea Kick:   punchy analog-style kick drum
// Trinity:    crunchy digital hi-hat
// Thyme:      bitcrushed delay with feedback
//
// All voices route through a lo-fi delay -> reverb chain

Engine_Jamstl : CroneEngine {

    var pg;
    var fxGroup;
    var voices;
    var params;
    var fxBus;
    var delaySynth;
    var reverbSynth;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        fxBus = Bus.audio(context.server, 2);

        pg = ParGroup.new(context.xg);
        fxGroup = Group.after(pg);

        voices = Dictionary.new;
        params = Dictionary.new;

        // --- defaults ---
        params[\wave] = 0;
        params[\pw] = 0.5;
        params[\bits] = 12;
        params[\sr] = 26000;
        params[\cutoff] = 2000;
        params[\res] = 0.3;
        params[\fmAmt] = 0;
        params[\fmRatio] = 2;
        params[\noiseAmt] = 0;
        params[\subAmt] = 0;
        params[\attack] = 0.005;
        params[\decay] = 0.15;
        params[\sustain] = 0.6;
        params[\release] = 0.3;
        params[\chaos] = 0;
        params[\lfo1Rate] = 2;
        params[\lfo2Rate] = 0.3;
        params[\pan] = 0;
        params[\kickFreq] = 60;
        params[\kickDecay] = 0.3;
        params[\hatDecay] = 0.08;
        params[\snareFreq] = 180;
        params[\snareDecay] = 0.18;
        params[\snareTone] = 0.5;

        // ======== SYNTHDEFS ========

        // --- Main voice (Kastl + Bitranger + Cinnamon) ---
        SynthDef(\kastl_voice, {
            arg out, freq=440, amp=0.5, pan=0, gate=1,
                wave=0, pw=0.5,
                bits=12, sr=26000,
                cutoff=2000, res=0.3,
                fmAmt=0, fmRatio=2,
                noiseAmt=0, subAmt=0,
                attack=0.005, decay=0.15, sustain=0.6, release=0.3,
                chaos=0, lfo1Rate=2, lfo2Rate=0.3;

            var sig, env, fm, sub, noise, filt;
            var lfo1, lfo2, chaosOsc;

            // internal modulation sources
            lfo1 = SinOsc.kr(lfo1Rate);
            lfo2 = LFTri.kr(lfo2Rate);
            chaosOsc = LFNoise1.kr(lfo1Rate * 2.7183) * chaos;

            // FM synthesis
            fm = SinOsc.ar(freq * fmRatio) * fmAmt * freq;

            // oscillator select
            sig = Select.ar(wave.round.asInteger.clip(0, 3), [
                Saw.ar(freq + fm),
                Pulse.ar(freq + fm, (pw + (lfo1 * 0.15 * chaos)).clip(0.01, 0.99)),
                LFTri.ar(freq + fm),
                WhiteNoise.ar
            ]);

            // sub oscillator + noise layer
            sub = SinOsc.ar(freq * 0.5) * subAmt;
            noise = PinkNoise.ar * noiseAmt;
            sig = sig + sub + noise;

            // bitcrush (Bitranger spirit)
            sig = sig.round(2.pow(1 - bits));
            sig = Latch.ar(sig, Impulse.ar(sr.clip(200, 48000) + (chaosOsc * 5000)));

            // resonant filter with chaos modulation (Cinnamon spirit)
            filt = (cutoff * (1 + (lfo1 * 0.4 * chaos) + (chaosOsc * 0.3))).clip(20, 18000);
            sig = MoogFF.ar(sig, filt, (res + (lfo2 * 0.15 * chaos)).clip(0, 3.5));

            // envelope
            env = EnvGen.kr(
                Env.adsr(attack, decay, sustain, release),
                gate, doneAction: Done.freeSelf
            );

            sig = sig * env * amp;
            sig = Pan2.ar(sig, (pan + (chaosOsc * 0.2)).clip(-1, 1));

            Out.ar(out, sig);
        }).add;

        // --- Kick drum (Tea Kick spirit) ---
        SynthDef(\kastl_kick, {
            arg out, freq=60, amp=0.8, decay=0.3;
            var sig, env, pitchEnv;
            pitchEnv = EnvGen.kr(Env.perc(0.001, 0.07)) * freq * 6;
            sig = SinOsc.ar(freq + pitchEnv);
            sig = sig + (WhiteNoise.ar(0.1) * EnvGen.kr(Env.perc(0.001, 0.015)));
            env = EnvGen.kr(Env.perc(0.003, decay), doneAction: Done.freeSelf);
            sig = (sig * env * amp).tanh;
            sig = sig.round(2.pow(-7));
            Out.ar(out, sig ! 2);
        }).add;

        // --- Snare drum (crunchy digital snare) ---
        SynthDef(\kastl_snare, {
            arg out, freq=180, amp=0.7, decay=0.18, tone=0.5;
            var body, noise, sig, env;
            // body: pitched sine with quick pitch drop
            body = SinOsc.ar(freq + (EnvGen.kr(Env.perc(0.001, 0.04)) * freq * 3));
            body = body * EnvGen.kr(Env.perc(0.001, decay * 0.6));
            // noise: filtered white noise for the snap
            noise = WhiteNoise.ar;
            noise = BPF.ar(noise, 3000 + (tone * 5000), 0.6);
            noise = noise * EnvGen.kr(Env.perc(0.003, decay));
            // mix body and noise
            sig = (body * tone) + (noise * (1 - tone * 0.3));
            env = EnvGen.kr(Env.perc(0.001, decay * 1.2), doneAction: Done.freeSelf);
            sig = (sig * env * amp).tanh;
            sig = sig.round(2.pow(-6));
            Out.ar(out, sig ! 2);
        }).add;

        // --- Hi-hat (Trinity spirit) ---
        SynthDef(\kastl_hat, {
            arg out, amp=0.5, decay=0.08;
            var sig, env;
            sig = WhiteNoise.ar + (HPF.ar(WhiteNoise.ar, 7000) * 2);
            sig = BPF.ar(sig, 9000, 0.5);
            env = EnvGen.kr(Env.perc(0.001, decay), doneAction: Done.freeSelf);
            sig = sig * env * amp * 0.4;
            sig = sig.round(2.pow(-6));
            Out.ar(out, sig ! 2);
        }).add;

        // --- Delay with bitcrush (Thyme spirit) ---
        SynthDef(\kastl_delay, {
            arg in, out, time=0.3, fb=0.4, mix=0.2, bits=12;
            var dry, wet;
            dry = In.ar(in, 2);
            wet = dry + (LocalIn.ar(2) * fb);
            wet = DelayC.ar(wet, 2.0, time.clip(0.001, 2.0));
            wet = wet.round(2.pow(1 - bits));
            LocalOut.ar(wet);
            Out.ar(out, (dry * (1 - mix)) + (wet * mix));
        }).add;

        // --- Reverb ---
        SynthDef(\kastl_reverb, {
            arg bus, mix=0.15, size=0.7, damp=0.5;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = FreeVerb2.ar(sig[0], sig[1], mix, size, damp);
            ReplaceOut.ar(bus, wet);
        }).add;

        context.server.sync;

        // start effects chain
        delaySynth = Synth(\kastl_delay, [
            \in, fxBus, \out, context.out_b,
            \time, 0.3, \fb, 0.4, \mix, 0.2, \bits, 12
        ], fxGroup);

        reverbSynth = Synth.after(delaySynth, \kastl_reverb, [
            \bus, context.out_b, \mix, 0.15, \size, 0.7
        ]);

        // ======== COMMANDS ========

        this.addCommand("note_on", "iff", { arg msg;
            var note = msg[1].asInteger;
            var freq = msg[2].asFloat;
            var vel = msg[3].asFloat;
            if(voices[note].notNil, {
                voices[note].set(\gate, 0);
                voices[note] = nil;
            });
            voices[note] = Synth(\kastl_voice, [
                \out, fxBus, \freq, freq, \amp, vel, \gate, 1,
                \wave, params[\wave], \pw, params[\pw],
                \bits, params[\bits], \sr, params[\sr],
                \cutoff, params[\cutoff], \res, params[\res],
                \fmAmt, params[\fmAmt], \fmRatio, params[\fmRatio],
                \noiseAmt, params[\noiseAmt], \subAmt, params[\subAmt],
                \attack, params[\attack], \decay, params[\decay],
                \sustain, params[\sustain], \release, params[\release],
                \chaos, params[\chaos],
                \lfo1Rate, params[\lfo1Rate], \lfo2Rate, params[\lfo2Rate],
                \pan, params[\pan]
            ], pg);
        });

        this.addCommand("note_off", "i", { arg msg;
            var note = msg[1].asInteger;
            if(voices[note].notNil, {
                voices[note].set(\gate, 0);
                voices[note] = nil;
            });
        });

        this.addCommand("kick", "f", { arg msg;
            Synth(\kastl_kick, [
                \out, fxBus, \freq, params[\kickFreq],
                \amp, msg[1].asFloat, \decay, params[\kickDecay]
            ], pg);
        });

        this.addCommand("hat", "f", { arg msg;
            Synth(\kastl_hat, [
                \out, fxBus, \amp, msg[1].asFloat,
                \decay, params[\hatDecay]
            ], pg);
        });

        this.addCommand("snare", "f", { arg msg;
            Synth(\kastl_snare, [
                \out, fxBus, \freq, params[\snareFreq],
                \amp, msg[1].asFloat, \decay, params[\snareDecay],
                \tone, params[\snareTone]
            ], pg);
        });

        // --- sound params ---
        this.addCommand("wave", "i", { arg msg; params[\wave] = msg[1].asInteger; });
        this.addCommand("pw", "f", { arg msg;
            params[\pw] = msg[1].asFloat;
            voices.do({ arg s; s.set(\pw, msg[1].asFloat) });
        });
        this.addCommand("bits", "f", { arg msg;
            params[\bits] = msg[1].asFloat;
            voices.do({ arg s; s.set(\bits, msg[1].asFloat) });
        });
        this.addCommand("sample_rate", "f", { arg msg;
            params[\sr] = msg[1].asFloat;
            voices.do({ arg s; s.set(\sr, msg[1].asFloat) });
        });
        this.addCommand("cutoff", "f", { arg msg;
            params[\cutoff] = msg[1].asFloat;
            voices.do({ arg s; s.set(\cutoff, msg[1].asFloat) });
        });
        this.addCommand("res", "f", { arg msg;
            params[\res] = msg[1].asFloat;
            voices.do({ arg s; s.set(\res, msg[1].asFloat) });
        });
        this.addCommand("fm_amt", "f", { arg msg;
            params[\fmAmt] = msg[1].asFloat;
            voices.do({ arg s; s.set(\fmAmt, msg[1].asFloat) });
        });
        this.addCommand("fm_ratio", "f", { arg msg;
            params[\fmRatio] = msg[1].asFloat;
            voices.do({ arg s; s.set(\fmRatio, msg[1].asFloat) });
        });
        this.addCommand("noise_amt", "f", { arg msg; params[\noiseAmt] = msg[1].asFloat; });
        this.addCommand("sub_amt", "f", { arg msg; params[\subAmt] = msg[1].asFloat; });
        this.addCommand("attack", "f", { arg msg; params[\attack] = msg[1].asFloat; });
        this.addCommand("decay", "f", { arg msg; params[\decay] = msg[1].asFloat; });
        this.addCommand("sustain_level", "f", { arg msg; params[\sustain] = msg[1].asFloat; });
        this.addCommand("release", "f", { arg msg; params[\release] = msg[1].asFloat; });
        this.addCommand("chaos", "f", { arg msg;
            params[\chaos] = msg[1].asFloat;
            voices.do({ arg s; s.set(\chaos, msg[1].asFloat) });
        });
        this.addCommand("lfo1_rate", "f", { arg msg;
            params[\lfo1Rate] = msg[1].asFloat;
            voices.do({ arg s; s.set(\lfo1Rate, msg[1].asFloat) });
        });
        this.addCommand("lfo2_rate", "f", { arg msg;
            params[\lfo2Rate] = msg[1].asFloat;
            voices.do({ arg s; s.set(\lfo2Rate, msg[1].asFloat) });
        });
        this.addCommand("pan", "f", { arg msg; params[\pan] = msg[1].asFloat; });
        this.addCommand("kick_tune", "f", { arg msg; params[\kickFreq] = msg[1].asFloat; });
        this.addCommand("kick_decay", "f", { arg msg; params[\kickDecay] = msg[1].asFloat; });
        this.addCommand("hat_decay", "f", { arg msg; params[\hatDecay] = msg[1].asFloat; });
        this.addCommand("snare_tune", "f", { arg msg; params[\snareFreq] = msg[1].asFloat; });
        this.addCommand("snare_decay", "f", { arg msg; params[\snareDecay] = msg[1].asFloat; });
        this.addCommand("snare_tone", "f", { arg msg; params[\snareTone] = msg[1].asFloat; });

        // --- fx params ---
        this.addCommand("delay_time", "f", { arg msg; delaySynth.set(\time, msg[1].asFloat); });
        this.addCommand("delay_fb", "f", { arg msg; delaySynth.set(\fb, msg[1].asFloat); });
        this.addCommand("delay_mix", "f", { arg msg; delaySynth.set(\mix, msg[1].asFloat); });
        this.addCommand("delay_bits", "f", { arg msg; delaySynth.set(\bits, msg[1].asFloat); });
        this.addCommand("reverb_mix", "f", { arg msg; reverbSynth.set(\mix, msg[1].asFloat); });
        this.addCommand("reverb_size", "f", { arg msg; reverbSynth.set(\size, msg[1].asFloat); });
    }

    free {
        voices.do({ arg s; s.free });
        delaySynth.free;
        reverbSynth.free;
        fxBus.free;
    }
}
