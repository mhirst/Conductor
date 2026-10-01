"""
Runs the real Conductor remote script against a simulated Live set, so the iOS app
can be developed without Ableton open.

    python3 RemoteScript/dev/fake_live.py

Then connect the app (or the simulator) to this Mac's IP, port 9001.
"""
import os
import sys
import time
import types

class _NoteSpec(object):
    def __init__(self, pitch, start_time, duration, velocity=100, mute=False):
        self.pitch, self.start_time, self.duration = pitch, start_time, duration
        self.velocity, self.mute = velocity, mute


_live = types.ModuleType('Live')
_live.Clip = types.SimpleNamespace(MidiNoteSpecification=_NoteSpec)
sys.modules['Live'] = _live

SCALES = {'Major': (0, 2, 4, 5, 7, 9, 11), 'Minor': (0, 2, 3, 5, 7, 8, 10), 'Dorian': (0, 2, 3, 5, 7, 9, 10),
          'Mixolydian': (0, 2, 4, 5, 7, 9, 10), 'Minor Pentatonic': (0, 3, 5, 7, 10),
          'Major Pentatonic': (0, 2, 4, 7, 9)}
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from Conductor.Conductor import Conductor  # noqa: E402


class Obs(object):
    """Minimal stand-in for Live's listener mechanism."""

    def __init__(self):
        object.__setattr__(self, '_ls', {})

    def __setattr__(self, name, value):
        old = self.__dict__.get(name, object())
        object.__setattr__(self, name, value)
        if not name.startswith('_') and old != value:
            for fn in list(self._ls.get(name, [])):
                fn()

    def _notify(self, prop):
        for fn in list(self._ls.get(prop, [])):
            fn()

    def __getattr__(self, name):
        if name.startswith('add_') and name.endswith('_listener'):
            prop = name[4:-9]
            return lambda fn: self._ls.setdefault(prop, []).append(fn)
        if name.startswith('remove_') and name.endswith('_listener'):
            prop = name[7:-9]
            return lambda fn: self._ls.get(prop, []).remove(fn)
        if name.endswith('_has_listener'):
            prop = name[:-13]
            return lambda fn: fn in self._ls.get(prop, [])
        raise AttributeError(name)


class Param(Obs):
    def __init__(self, name, value, lo=0.0, hi=1.0, items=None, unit=''):
        Obs.__init__(self)
        self.name = name
        self.min = lo
        self.max = hi
        self.value = value
        self.is_quantized = items is not None
        self.value_items = tuple(items or ())
        self.is_enabled = True
        self._unit = unit

    def str_for_value(self, v):
        if self.is_quantized:
            return self.value_items[int(round(v))]
        if self._unit == 'dB':
            return '-inf dB' if v <= 0.001 else '%.1f dB' % (40 * (v - 0.85) / 0.85 * 1.5)
        if self._unit == 'pan':
            return 'C' if abs(v) < 0.01 else ('%dL' % (-v * 50) if v < 0 else '%dR' % (v * 50))
        if self._unit == 'Hz':
            return '%d Hz' % (20 * (1000 ** v))
        return '%d %%' % (100 * (v - self.min) / (self.max - self.min))


class Chain(Obs):
    def __init__(self, name, devices):
        Obs.__init__(self)
        self.name = name
        self.devices = devices


class Device(Obs):
    def __init__(self, name, class_name, params, chains=None):
        Obs.__init__(self)
        self.name = name
        self.class_name = class_name
        self.parameters = [Param('Device On', 1.0, 0.0, 1.0, ['Off', 'On'])] + params
        self.can_have_chains = chains is not None
        self.chains = chains or []
        self.is_active = True
        self.parameters[0].add_value_listener(self._on_power)

    def _on_power(self):
        self.is_active = self.parameters[0].value > 0.5


class Clip(Obs):
    def __init__(self, name, color, length=4.0):
        Obs.__init__(self)
        self.name = name
        self.color = color
        self.length = length
        self.looping = True
        self.loop_start = 0.0
        self.loop_end = length
        self.start_marker = 0.0
        self.end_marker = length
        self.is_playing = False
        self.is_triggered = False
        self.is_recording = False
        self.playing_position = 0.0
        self.is_midi_clip = True
        self._notes = []

    def _match(self, fp, ps, ft, ts):
        return [n for n in self._notes if fp <= n.pitch < fp + ps and ft <= n.start_time < ft + ts]

    def get_notes_extended(self, from_pitch, pitch_span, from_time, time_span):
        return tuple(self._match(from_pitch, pitch_span, from_time, time_span))

    def remove_notes_extended(self, from_pitch, pitch_span, from_time, time_span):
        gone = self._match(from_pitch, pitch_span, from_time, time_span)
        self._notes = [n for n in self._notes if n not in gone]
        self._notify('notes')

    def add_new_notes(self, specs):
        self._notes.extend(specs)
        self._notify('notes')

    def duplicate_loop(self):
        length = self.loop_end - self.loop_start
        self._notes += [_NoteSpec(n.pitch, n.start_time + length, n.duration, n.velocity)
                        for n in self._notes if self.loop_start <= n.start_time < self.loop_end]
        self.end_marker = self.loop_end + length
        self.loop_end = self.loop_end + length
        self._notify('notes')


class DrumPad(Obs):
    def __init__(self, note, name):
        Obs.__init__(self)
        self.note = note
        self.name = name
        self.chains = [Chain(name, [])] if name else []


PAD_NAMES = {36: 'Kick', 37: 'Rim', 38: 'Snare', 39: 'Clap', 40: 'Snare 2', 41: 'Tom Lo', 42: 'Hat Closed',
             43: 'Tom Mid', 44: 'Hat Pedal', 45: 'Tom Hi', 46: 'Hat Open', 47: 'Shaker', 48: 'Conga',
             49: 'Crash', 50: 'Cowbell', 51: 'Ride'}


class ClipSlot(Obs):
    def __init__(self, track, clip=None):
        Obs.__init__(self)
        self._track = track
        self.clip = clip
        self.has_clip = clip is not None
        self.has_stop_button = True
        self.controls_other_clips = False
        self.is_triggered = False
        self.playing_status = 0

    def create_clip(self, length):
        self.clip = Clip('', self._track.color, length)
        self.has_clip = True

    def fire(self):
        self._track._trigger(self)

    def stop(self):
        if self.clip is not None and self.clip.is_playing:
            self._track._trigger(None)


class Mixer(object):
    def __init__(self, n_sends):
        self.volume = Param('Volume', 0.85, 0.0, 1.0, unit='dB')
        self.panning = Param('Pan', 0.0, -1.0, 1.0, unit='pan')
        self.sends = [Param('Send %s' % chr(65 + i), 0.0) for i in range(n_sends)]


class Track(Obs):
    def __init__(self, song, name, color, clips=(), devices=(), n_sends=2, armable=True):
        Obs.__init__(self)
        self._song = song
        self.name = name
        self.color = color
        self.mute = False
        self.solo = False
        self.can_be_armed = armable
        self.arm = False
        self.is_foldable = False
        self.fold_state = False
        self.is_grouped = False
        self.group_track = None
        self.playing_slot_index = -1
        self.fired_slot_index = -1
        self.mixer_device = Mixer(n_sends)
        self.has_audio_output = True
        self.has_midi_input = armable
        self.implicit_arm = False
        self.output_meter_left = 0.0
        self.output_meter_right = 0.0
        self.devices = list(devices)
        self.clip_slots = [ClipSlot(self, c) for c in clips]
        self._pending = 'none'

    def _trigger(self, slot):
        if not self._song.is_playing:
            self._song.start_playing()
        for s in self.clip_slots:
            if s.clip is not None:
                s.clip.is_triggered = False
            s.is_triggered = False
        if slot is None or slot.clip is None:
            self._pending = None
            self.fired_slot_index = -2
        else:
            self._pending = slot
            slot.clip.is_triggered = True
            slot.is_triggered = True
            self.fired_slot_index = self.clip_slots.index(slot)

    def stop_all_clips(self):
        self._trigger(None)

    def _launch(self):
        if self._pending == 'none':
            return
        for s in self.clip_slots:
            if s.clip is not None:
                s.clip.is_playing = False
                s.clip.is_triggered = False
            s.is_triggered = False
            s.playing_status = 0
        if self._pending is None:
            self.playing_slot_index = -1
        else:
            slot = self._pending
            slot.clip.playing_position = 0.0
            slot.clip.is_playing = True
            slot.playing_status = 1
            self.playing_slot_index = self.clip_slots.index(slot)
        self.fired_slot_index = -1
        self._pending = 'none'


class Scene(Obs):
    def __init__(self, song, index, name, color):
        Obs.__init__(self)
        self._song = song
        self._index = index
        self.name = name
        self.color = color
        self.is_triggered = False

    def fire(self):
        self.is_triggered = True
        for t in self._song.tracks:
            t.clip_slots[self._index].fire()


class View(Obs):
    def __init__(self, song):
        Obs.__init__(self)
        self._song = song
        self.selected_track = None

    def select_device(self, device):
        self._song.appointed_device = device


class Song(Obs):
    def __init__(self):
        Obs.__init__(self)
        self.tempo = 124.0
        self.is_playing = False
        self.metronome = False
        self.signature_numerator = 4
        self.signature_denominator = 4
        self.session_record = False
        self.record_mode = False
        self.can_undo = True
        self.can_redo = False
        self.current_song_time = 0.0
        self.appointed_device = None
        self.view = View(self)
        self.root_note = 9
        self.scale_name = 'Minor'
        self.scale_intervals = SCALES['Minor']
        self.add_scale_name_listener(
            lambda: setattr(self, 'scale_intervals', SCALES.get(self.scale_name, SCALES['Major'])))

        colors = [0xFF6E6E, 0xFFA84F, 0xF5E663, 0x8BE36F, 0x4FD1C5, 0x6FA8FF, 0xB48CFF, 0xFF7EC8]
        names = ['Drums', 'Snare', 'Hats', 'Perc', 'Bass', 'Keys', 'Lead', 'Pad']
        n_scenes = 12

        def fx(name):
            return Device(name, 'AutoFilter' if 'Filter' in name else 'Reverb', [
                Param('Frequency', 0.6, unit='Hz'), Param('Resonance', 0.2),
                Param('Dry/Wet', 1.0), Param('Mode', 0.0, 0.0, 2.0, ['LP', 'HP', 'BP']),
            ])

        self.tracks = []
        for i, (n, c) in enumerate(zip(names, colors)):
            clips = []
            for s in range(n_scenes):
                has = (s + i) % 3 != 2 and s < 9
                clips.append(Clip('%s %d' % (n, s + 1), c, 4.0 * (1 + (s % 2))) if has else None)
            devices = [
                Device('Serum' if n in ('Lead', 'Pad') else 'Simpler',
                       'AuPluginDevice' if n in ('Lead', 'Pad') else 'OriginalSimpler',
                       [Param('Macro %d' % k, 0.3 + 0.05 * k) for k in range(1, 13)]),
                fx('Auto Filter'),
                Device('FX Rack', 'AudioEffectGroupDevice',
                       [Param('Macro %d' % k, 0.0) for k in range(1, 9)],
                       chains=[Chain('Wet', [fx('Reverb')]), Chain('Crush', [fx('Filter Delay')])]),
            ]
            if n == 'Drums':
                rack = Device('Drum Rack', 'DrumGroupDevice', [Param('Macro %d' % k, 0.0) for k in range(1, 9)],
                              chains=[Chain(PAD_NAMES[k], []) for k in sorted(PAD_NAMES)])
                rack.can_have_drum_pads = True
                rack.drum_pads = [DrumPad(k, PAD_NAMES.get(k, '')) for k in range(128)]
                devices = [rack] + devices[1:]
                beat = clips[0]
                for st in range(16):
                    if st % 4 == 0:
                        beat._notes.append(_NoteSpec(36, st * 0.25, 0.25))
                    if st % 8 == 4:
                        beat._notes.append(_NoteSpec(38, st * 0.25, 0.25))
                    if st % 2 == 0:
                        beat._notes.append(_NoteSpec(42, st * 0.25, 0.25, 80))
            self.tracks.append(Track(self, n, c, clips, devices, n_sends=2, armable=True))
        self.view.highlighted_clip_slot = None
        self.return_tracks = [
            Track(self, 'A-Reverb', 0x9E9E9E, devices=[fx('Reverb')], n_sends=2, armable=False),
            Track(self, 'B-Delay', 0x9E9E9E, devices=[fx('Filter Delay')], n_sends=2, armable=False),
        ]
        self.master_track = Track(self, 'Master', 0xDDDDDD, devices=[fx('Glue Filter')], n_sends=0, armable=False)
        self.scenes = [Scene(self, s, 'Intro' if s == 0 else ('Drop' if s == 4 else ''), 0) for s in range(n_scenes)]

    # transport
    def start_playing(self):
        self.current_song_time = 0.0
        self.is_playing = True

    def continue_playing(self):
        self.is_playing = True

    def stop_playing(self):
        self.is_playing = False
        for t in self.tracks:
            t._pending = None
            t._launch()

    def stop_all_clips(self):
        for t in self.tracks:
            t.stop_all_clips()

    def tap_tempo(self):
        pass

    def undo(self):
        pass

    def redo(self):
        pass

    def _update_meters(self):
        import random
        total = 0.0
        for t in self.tracks + self.return_tracks:
            playing = self.is_playing and t.playing_slot_index >= 0 and not t.mute
            beat_phase = self.current_song_time % 1.0
            base = (0.55 + 0.3 * (1 - beat_phase)) * t.mixer_device.volume.value / 0.85 if playing else 0.0
            t.output_meter_left = min(1.0, base * random.uniform(0.85, 1.0))
            t.output_meter_right = min(1.0, base * random.uniform(0.85, 1.0))
            total += t.output_meter_left
        m = self.master_track
        m.output_meter_left = m.output_meter_right = min(1.0, total / 4.0)

    def advance(self, dt):
        self._update_meters()
        if not self.is_playing:
            return
        before = self.current_song_time
        self.current_song_time = before + dt * self.tempo / 60.0
        # Launch quantization: 1 bar.
        if int(self.current_song_time / 4) != int(before / 4) or before == 0:
            for t in self.tracks:
                t._launch()
            for sc in self.scenes:
                sc.is_triggered = False
        for t in self.tracks:
            if t.playing_slot_index >= 0:
                clip = t.clip_slots[t.playing_slot_index].clip
                clip.playing_position = (clip.playing_position + dt * self.tempo / 60.0) % clip.loop_end


class CInstance(object):
    def __init__(self, song):
        self._song = song

    def song(self):
        return self._song

    def log_message(self, msg):
        print(msg, flush=True)

    def show_message(self, msg):
        print('[status bar] ' + msg, flush=True)


def main():
    song = Song()
    script = Conductor(CInstance(song))
    last = time.time()
    try:
        while True:
            time.sleep(0.1)
            now = time.time()
            song.advance(now - last)
            last = now
            script.update_display()
    except KeyboardInterrupt:
        pass
    finally:
        script.disconnect()


if __name__ == '__main__':
    main()
