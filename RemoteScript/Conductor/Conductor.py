"""
Conductor — Ableton Live remote script that exposes the session over TCP.

Protocol: newline-delimited JSON on TCP port 9001.
  client -> server: {"cmd": "...", ...}
  server -> client: {"type": "...", ...}

Everything that touches the Live API happens on Live's main thread inside
update_display() (~every 100 ms). Listeners only mark things dirty; the tick
coalesces them and pushes updates to every connected client.
"""
import Live
import errno
import json
import os
import socket
import subprocess
import sys

PORT = 9001
SERVICE_TYPE = '_conductor._tcp'
PROTOCOL_VERSION = 1
MAX_WBUF = 8 * 1024 * 1024
RETRY_TICKS = 50


def _color(obj):
    try:
        return int(obj.color)
    except Exception:
        return 0


def _pstr(param):
    try:
        return param.str_for_value(param.value)
    except Exception:
        try:
            return str(param)
        except Exception:
            return ''


class _Client(object):
    def __init__(self, sock, addr):
        self.sock = sock
        self.addr = addr
        self.rbuf = b''
        self.wbuf = bytearray()
        self.closed = False


class Conductor(object):

    def __init__(self, c_instance):
        self._c = c_instance
        self._server = None
        self._retry = 0
        self._clients = []
        self._song_listeners = []
        self._struct_listeners = []
        self._clip_listeners = {}
        self._tree_listeners = []
        self._param_listeners = []
        self._tracks = []
        self._n_tracks = 0
        self._n_returns = 0
        self._dirty = set()
        self._needs_full = False
        self._watch = None        # track whose device chain the app shows
        self._focus = None        # device whose params the app shows
        self._bonjour = None
        self._last_meters = None
        self.reload_requested = False
        self._lock_base = {}      # "t:s:path:i" -> base (unlocked) value for p-lock lanes
        self._inst = None         # track the pads/keys play into (implicitly armed, like Push)
        self._seq_track = None    # step sequencer target clip = (track, slot index)
        self._seq_s = -1
        self._seq_listeners = []
        self._seq_last_pos = None

        self._open_server()
        self._add_song_listeners()
        self._rebuild(send=False)
        self._start_bonjour()
        self._log('Conductor loaded (hot-reload enabled), listening on port %d' % PORT)
        self._c.show_message('Conductor: listening on port %d' % PORT)

    # ── Live control-surface interface ──────────────────────────────────────

    def suggest_input_port(self):
        return ''

    def suggest_output_port(self):
        return ''

    def can_lock_to_devices(self):
        return False

    def connect_script_instances(self, instanciated_scripts):
        pass

    def build_midi_map(self, midi_map_handle):
        pass

    def receive_midi(self, midi_bytes):
        pass

    def refresh_state(self):
        self._needs_full = True

    def update_display(self):
        try:
            self._poll_network()
            if self._needs_full:
                self._rebuild()
            self._flush_dirty()
            self._send_progress()
            self._send_meters()
            self._send_seqpos()
            for c in self._clients:
                self._flush(c)
            self._reap()
        except Exception as e:
            self._log('tick error: %s' % e)

    def disconnect(self):
        self._unlisten(self._song_listeners)
        self._unlisten(self._struct_listeners)
        for bucket in self._clip_listeners.values():
            self._unlisten(bucket)
        self._unlisten(self._tree_listeners)
        self._unlisten(self._param_listeners)
        self._unlisten(self._seq_listeners)
        self._release_implicit_arm()
        for c in self._clients:
            try:
                c.sock.close()
            except Exception:
                pass
        self._clients = []
        if self._server is not None:
            try:
                self._server.close()
            except Exception:
                pass
            self._server = None
        if self._bonjour is not None:
            try:
                self._bonjour.terminate()
            except Exception:
                pass
            self._bonjour = None

    # ── Helpers ─────────────────────────────────────────────────────────────

    def _song(self):
        return self._c.song()

    def _log(self, msg):
        self._c.log_message('[Conductor] ' + msg)

    def _listen(self, bucket, subject, prop, fn):
        try:
            if not getattr(subject, '%s_has_listener' % prop)(fn):
                getattr(subject, 'add_%s_listener' % prop)(fn)
                bucket.append((subject, prop, fn))
        except Exception as e:
            self._log('listen %s failed: %s' % (prop, e))

    def _unlisten(self, bucket):
        for subject, prop, fn in bucket:
            try:
                if getattr(subject, '%s_has_listener' % prop)(fn):
                    getattr(subject, 'remove_%s_listener' % prop)(fn)
            except Exception:
                pass
        del bucket[:]

    def _mark(self, *key):
        self._dirty.add(key)

    def _kind(self, t):
        if t < self._n_tracks:
            return 'track'
        if t < self._n_tracks + self._n_returns:
            return 'return'
        return 'master'

    # ── Networking ──────────────────────────────────────────────────────────

    def _open_server(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(('0.0.0.0', PORT))
            s.listen(4)
            s.setblocking(False)
            self._server = s
        except Exception as e:
            self._server = None
            self._log('could not open port %d: %s' % (PORT, e))

    def _start_bonjour(self):
        # Advertise via the system mDNS responder so the app can find us.
        if sys.platform != 'darwin' or not os.path.exists('/usr/bin/dns-sd'):
            return
        try:
            name = socket.gethostname().split('.')[0] or 'Ableton Live'
            self._bonjour = subprocess.Popen(
                ['/usr/bin/dns-sd', '-R', name, SERVICE_TYPE, 'local', str(PORT)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL)
        except Exception as e:
            self._log('bonjour failed: %s' % e)

    def _poll_network(self):
        if self._server is None:
            self._retry += 1
            if self._retry >= RETRY_TICKS:
                self._retry = 0
                self._open_server()
            return
        while True:
            try:
                sock, addr = self._server.accept()
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                break
            sock.setblocking(False)
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except Exception:
                pass
            c = _Client(sock, addr)
            self._clients.append(c)
            self._log('client connected from %s' % (addr,))
            self._send(c, {'type': 'hello', 'version': PROTOCOL_VERSION,
                           'host': socket.gethostname().split('.')[0]})
            self._send(c, self._state_msg())
            if self._watch is not None:
                self._send(c, self._devices_msg())
            if self._focus is not None:
                self._send(c, self._device_msg())
            if self._inst is not None:
                self._send(c, self._instrument_msg())
            if self._seq_track is not None:
                self._send(c, self._seq_msg())
        for c in self._clients:
            self._read(c)

    def _read(self, c):
        while not c.closed:
            try:
                data = c.sock.recv(65536)
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                c.closed = True
                break
            if not data:
                c.closed = True
                break
            c.rbuf += data
        while b'\n' in c.rbuf:
            line, c.rbuf = c.rbuf.split(b'\n', 1)
            line = line.strip()
            if not line:
                continue
            try:
                self._handle(c, json.loads(line.decode('utf-8')))
            except Exception as e:
                self._log('command failed: %s (%r)' % (e, line[:200]))
                self._send(c, {'type': 'error', 'message': str(e)})

    def _send(self, c, msg):
        if c.closed:
            return
        c.wbuf += (json.dumps(msg, separators=(',', ':')) + '\n').encode('utf-8')
        if len(c.wbuf) > MAX_WBUF:
            self._log('client %s too slow, dropping' % (c.addr,))
            c.closed = True

    def _broadcast(self, msg):
        if not self._clients:
            return
        data = (json.dumps(msg, separators=(',', ':')) + '\n').encode('utf-8')
        for c in self._clients:
            if not c.closed:
                c.wbuf += data

    def _flush(self, c):
        while c.wbuf and not c.closed:
            try:
                n = c.sock.send(c.wbuf)
            except (BlockingIOError, InterruptedError):
                break
            except OSError as e:
                if getattr(e, 'errno', None) in (errno.EAGAIN, errno.EWOULDBLOCK):
                    break
                c.closed = True
                break
            del c.wbuf[:n]

    def _reap(self):
        alive = []
        for c in self._clients:
            if c.closed:
                try:
                    c.sock.close()
                except Exception:
                    pass
                self._log('client %s disconnected' % (c.addr,))
            else:
                alive.append(c)
        self._clients = alive

    # ── Listeners ───────────────────────────────────────────────────────────

    def _add_song_listeners(self):
        song = self._song()
        b = self._song_listeners
        full = lambda: setattr(self, '_needs_full', True)
        for prop in ('tracks', 'return_tracks', 'scenes'):
            self._listen(b, song, prop, full)
        mark_song = lambda: self._mark('song')
        for prop in ('tempo', 'is_playing', 'metronome', 'signature_numerator',
                     'signature_denominator', 'session_record', 'record_mode'):
            self._listen(b, song, prop, mark_song)
        self._listen(b, song, 'appointed_device', lambda: self._mark('appointed'))
        # Live 12 song scale (Push 3 keys follow it).
        for prop in ('root_note', 'scale_name'):
            if hasattr(song, prop):
                self._listen(b, song, prop, mark_song)

    def _rebuild(self, send=True):
        """(Re)attach per-track/scene/slot listeners and push full state."""
        self._needs_full = False
        self._unlisten(self._struct_listeners)
        for bucket in self._clip_listeners.values():
            self._unlisten(bucket)
        self._clip_listeners = {}

        song = self._song()
        self._n_tracks = len(song.tracks)
        self._n_returns = len(song.return_tracks)
        self._tracks = list(song.tracks) + list(song.return_tracks) + [song.master_track]
        b = self._struct_listeners

        for t, track in enumerate(self._tracks):
            kind = self._kind(t)
            mark = (lambda t=t: self._mark('track', t))
            props = ['name', 'color']
            if kind != 'master':
                props += ['mute', 'solo']
            if kind == 'track':
                props += ['playing_slot_index', 'fired_slot_index']
                if track.can_be_armed:
                    props.append('arm')
                if track.is_foldable:
                    props.append('fold_state')
            for prop in props:
                self._listen(b, track, prop, mark)
            mixer = track.mixer_device
            self._listen(b, mixer.volume, 'value', mark)
            self._listen(b, mixer.panning, 'value', mark)
            for send_param in mixer.sends:
                self._listen(b, send_param, 'value', mark)
            # Mixer shows each track's top-level devices with on/off toggles.
            self._listen(b, track, 'devices', lambda: setattr(self, '_needs_full', True))
            for d in track.devices:
                self._listen(b, d, 'is_active', mark)
                self._listen(b, d, 'name', mark)
            if kind == 'track':
                for s, slot in enumerate(track.clip_slots):
                    on_slot = (lambda t=t, s=s: self._mark('slot', t, s))
                    on_has_clip = (lambda t=t, s=s: (self._mark('relisten', t, s),
                                                     self._mark('slot', t, s)))
                    self._listen(b, slot, 'has_clip', on_has_clip)
                    self._listen(b, slot, 'playing_status', on_slot)
                    self._listen(b, slot, 'is_triggered', on_slot)
                    self._listen_clip(t, s)

        for s, scene in enumerate(song.scenes):
            mark = (lambda s=s: self._mark('scene', s))
            for prop in ('name', 'color', 'is_triggered'):
                self._listen(b, scene, prop, mark)

        # Keep device watch/focus alive across structure changes if the objects survive.
        if self._watch is not None and self._index_of_track(self._watch) < 0:
            self._watch = None
        if self._focus is not None and self._locate(self._focus) is None:
            self._focus = None
        if self._inst is not None and self._index_of_track(self._inst) < 0:
            self._inst = None
        if self._seq_track is not None and self._index_of_track(self._seq_track) < 0:
            self._seq_track = None
        self._listen_tree()
        self._listen_focus()
        self._listen_seq()

        self._dirty.clear()
        if send:
            self._broadcast(self._state_msg())
            self._broadcast(self._devices_msg())
            self._broadcast(self._device_msg())
            self._broadcast(self._instrument_msg())
            self._broadcast(self._seq_msg())

    def _listen_clip(self, t, s):
        bucket = self._clip_listeners.setdefault((t, s), [])
        self._unlisten(bucket)
        try:
            slot = self._tracks[t].clip_slots[s]
        except Exception:
            return
        if slot.has_clip:
            mark = (lambda t=t, s=s: self._mark('slot', t, s))
            for prop in ('name', 'color', 'is_recording'):
                self._listen(bucket, slot.clip, prop, mark)

    def _listen_tree(self):
        self._unlisten(self._tree_listeners)
        if self._watch is None:
            return
        b = self._tree_listeners
        mark = lambda: self._mark('devices')

        def walk(devices_owner):
            self._listen(b, devices_owner, 'devices', mark)
            for d in devices_owner.devices:
                self._listen(b, d, 'name', mark)
                self._listen(b, d, 'is_active', mark)
                if d.can_have_chains:
                    self._listen(b, d, 'chains', mark)
                    for chain in d.chains:
                        walk(chain)
        try:
            walk(self._watch)
        except Exception as e:
            self._log('tree listen failed: %s' % e)

    def _listen_focus(self):
        self._unlisten(self._param_listeners)
        if self._focus is None:
            return
        b = self._param_listeners
        self._listen(b, self._focus, 'parameters', lambda: self._mark('device'))
        self._listen(b, self._focus, 'name', lambda: self._mark('device'))
        for i, p in enumerate(self._focus.parameters):
            self._listen(b, p, 'value', (lambda i=i: self._mark('param', i)))

    # ── Dirty flush ─────────────────────────────────────────────────────────

    def _flush_dirty(self):
        if not self._dirty:
            return
        dirty, self._dirty = self._dirty, set()
        # Relisten clips before we serialise their slots.
        for key in dirty:
            if key[0] == 'relisten':
                self._listen_clip(key[1], key[2])
        if 'devices' in [k[0] for k in dirty]:
            if self._focus is not None and self._locate(self._focus) is None:
                self._focus = None
                self._listen_focus()
                dirty.add(('device',))
            self._listen_tree()
        if not self._clients:
            return
        for key in dirty:
            kind = key[0]
            try:
                if kind == 'track':
                    t = key[1]
                    self._broadcast({'type': 'track', 'track': self._track_info(t, self._tracks[t])})
                elif kind == 'slot':
                    t, s = key[1], key[2]
                    slot = self._tracks[t].clip_slots[s]
                    self._broadcast({'type': 'slot', 't': t, 's': s, 'slot': self._slot_info(slot)})
                elif kind == 'scene':
                    s = key[1]
                    self._broadcast({'type': 'scene', 's': s,
                                     'scene': self._scene_info(self._song().scenes[s])})
                elif kind == 'song':
                    self._broadcast({'type': 'song', 'song': self._song_info()})
                elif kind == 'appointed':
                    self._broadcast(self._appointed_msg())
                elif kind == 'devices':
                    self._broadcast(self._devices_msg())
                elif kind == 'device':
                    self._listen_focus()
                    self._broadcast(self._device_msg())
                elif kind == 'seq':
                    self._listen_seq()
                    self._broadcast(self._seq_msg())
                elif kind == 'param' and self._focus is not None:
                    i = key[1]
                    p = self._focus.parameters[i]
                    self._broadcast({'type': 'param', 'i': i, 'value': p.value, 'display': _pstr(p)})
            except Exception as e:
                self._log('flush %r failed: %s' % (key, e))

    def _send_progress(self):
        if not self._clients:
            return
        song = self._song()
        if not song.is_playing:
            return
        clips = []
        for t in range(self._n_tracks):
            track = self._tracks[t]
            try:
                s = track.playing_slot_index
                if s < 0:
                    continue
                slot = track.clip_slots[s]
                if not slot.has_clip:
                    continue
                clip = slot.clip
                if not clip.is_playing:
                    continue
                if clip.looping:
                    start, end = clip.loop_start, clip.loop_end
                else:
                    start, end = clip.start_marker, clip.end_marker
                length = end - start
                if length <= 0:
                    continue
                frac = (clip.playing_position - start) / length
                clips.append([t, s, round(max(0.0, min(1.0, frac)), 4)])
            except Exception:
                continue
        self._broadcast({'type': 'progress', 'beat': song.current_song_time, 'clips': clips})

    def _send_meters(self):
        if not self._clients:
            return
        levels = []
        for track in self._tracks:
            try:
                if getattr(track, 'has_audio_output', True):
                    levels.append([round(track.output_meter_left, 3), round(track.output_meter_right, 3)])
                else:
                    levels.append([0, 0])
            except Exception:
                levels.append([0, 0])
        silent = not any(l or r for l, r in levels)
        if silent and self._last_meters == 'silent':
            return
        self._last_meters = 'silent' if silent else 'active'
        self._broadcast({'type': 'meters', 'levels': levels})

    # ── Instrument & sequencer (Push-style) ─────────────────────────────────

    def _release_implicit_arm(self):
        if self._inst is not None:
            try:
                self._inst.implicit_arm = False
            except Exception:
                pass

    def _set_instrument(self, t):
        track = self._tracks[t] if 0 <= t < self._n_tracks else None
        if self._inst is not None and track is not None and self._inst == track:
            return
        self._release_implicit_arm()
        self._inst = track
        if track is None:
            return
        self._song().view.selected_track = track
        if track.can_be_armed and not track.arm:
            try:
                track.implicit_arm = True     # Push's auto-arm; not saved with the set
            except Exception:
                track.arm = True

    def _drum_rack(self, track):
        """First Drum Rack on the track, including ones nested in racks (Core Library kits
        wrap the Drum Rack in an Instrument Rack)."""
        def find(devices, depth):
            for d in devices:
                if getattr(d, 'can_have_drum_pads', False):
                    return d
                if depth < 3 and getattr(d, 'can_have_chains', False):
                    for chain in d.chains:
                        found = find(chain.devices, depth + 1)
                        if found is not None:
                            return found
            return None
        return find(track.devices, 0)

    def _instrument_msg(self):
        if self._inst is None:
            return {'type': 'instrument', 't': -1, 'isDrum': False, 'pads': []}
        rack = self._drum_rack(self._inst)
        pads = []
        if rack is not None:
            for p in rack.drum_pads:
                try:
                    pads.append(p.name if len(p.chains) else '')
                except Exception:
                    pads.append('')
        return {'type': 'instrument', 't': self._index_of_track(self._inst),
                'isDrum': rack is not None, 'pads': pads}

    def _seq_watch(self, t, s):
        if not (0 <= t < self._n_tracks):
            self._seq_track = None
            self._listen_seq()
            return
        track = self._tracks[t]
        if s < 0:
            # Default like Push: the playing clip, else the highlighted slot, else the first clip.
            s = track.playing_slot_index
            if s < 0:
                hl = self._song().view.highlighted_clip_slot
                slots = list(track.clip_slots)
                for i, slot in enumerate(slots):
                    try:
                        if hl is not None and slot == hl:
                            s = i
                            break
                    except Exception:
                        pass
            if s < 0:
                s = next((i for i, sl in enumerate(track.clip_slots) if sl.has_clip), 0)
        self._seq_track = track
        self._seq_s = max(0, min(s, len(track.clip_slots) - 1))
        self._listen_seq()

    def _seq_slot(self):
        if self._seq_track is None:
            return None
        try:
            return self._seq_track.clip_slots[self._seq_s]
        except Exception:
            return None

    def _seq_clip(self):
        slot = self._seq_slot()
        if slot is None or not slot.has_clip:
            return None
        clip = slot.clip
        return clip if getattr(clip, 'is_midi_clip', True) else None

    def _listen_seq(self):
        self._unlisten(self._seq_listeners)
        slot = self._seq_slot()
        if slot is None:
            return
        b = self._seq_listeners
        mark = lambda: self._mark('seq')
        self._listen(b, slot, 'has_clip', mark)
        clip = self._seq_clip()
        if clip is not None:
            for prop in ('notes', 'loop_start', 'loop_end', 'name'):
                self._listen(b, clip, prop, mark)

    def _seq_msg(self):
        msg = {'type': 'seq', 't': -1, 's': -1, 'hasClip': False, 'isAudio': False, 'name': '',
               'loopStart': 0.0, 'loopEnd': 4.0, 'notes': []}
        slot = self._seq_slot()
        if slot is None:
            return msg
        msg['t'] = self._index_of_track(self._seq_track)
        msg['s'] = self._seq_s
        if slot.has_clip and not getattr(slot.clip, 'is_midi_clip', True):
            msg['isAudio'] = True
            return msg
        clip = self._seq_clip()
        if clip is None:
            return msg
        msg.update(hasClip=True, name=clip.name, loopStart=clip.loop_start, loopEnd=clip.loop_end)
        start = min(0.0, clip.start_marker, clip.loop_start)
        span = max(clip.end_marker, clip.loop_end) - start + 1
        notes = clip.get_notes_extended(0, 128, start, span)
        msg['notes'] = [[n.pitch, round(n.start_time, 4), round(n.duration, 4), int(n.velocity), 1 if n.mute else 0]
                        for n in notes]
        return msg

    def _seq_toggle(self, msg):
        slot = self._seq_slot()
        if slot is None:
            raise ValueError('no sequencer clip selected')
        pitch = int(msg['pitch'])
        start = float(msg['start'])
        step = float(msg['duration'])
        if not slot.has_clip:
            if not getattr(self._seq_track, 'has_midi_input', False):
                raise ValueError('sequencer needs a MIDI track')
            slot.create_clip(float(msg.get('clipLength', 4.0)))
        clip = slot.clip
        if not getattr(clip, 'is_midi_clip', True):
            raise ValueError('cannot sequence an audio clip')
        lo = max(0.0, start - 0.001)
        if clip.get_notes_extended(pitch, 1, lo, step):
            clip.remove_notes_extended(pitch, 1, lo, step)
        else:
            gate = float(msg.get('gate', 1.0))
            clip.add_new_notes((Live.Clip.MidiNoteSpecification(
                pitch=pitch, start_time=start, duration=step * gate,
                velocity=float(msg.get('velocity', 100)), mute=False),))

    def _seq_length(self, length):
        clip = self._seq_clip()
        if clip is None or length <= 0:
            return
        end = clip.loop_start + length
        if end > clip.end_marker:
            clip.end_marker = end
            clip.loop_end = end
        else:
            clip.loop_end = end
            clip.end_marker = end

    # ── Browser (Push-style) ────────────────────────────────────────────────
    # Items are addressed by category key + a path of child indices, fetched one level
    # at a time: the full library is far too big to send at once.

    BROWSER_CATEGORIES = (
        ('sounds', 'Sounds'), ('drums', 'Drums'), ('instruments', 'Instruments'),
        ('audio_effects', 'Audio Effects'), ('midi_effects', 'MIDI Effects'),
        ('max_for_live', 'Max for Live'), ('plugins', 'Plug-ins'), ('clips', 'Clips'),
        ('samples', 'Samples'), ('packs', 'Packs'), ('user_library', 'User Library'),
        ('current_project', 'Current Project'),
    )
    BROWSER_LIMIT = 3000

    def _browser(self):
        return Live.Application.get_application().browser

    def _browser_categories(self):
        b = self._browser()
        cats = []
        for i, col in enumerate(getattr(b, 'colors', []) or []):
            try:
                if len(col.children):
                    cats.append({'key': 'color:%d' % i, 'name': col.name})
            except Exception:
                pass
        for key, name in self.BROWSER_CATEGORIES:
            if getattr(b, key, None) is not None:
                cats.append({'key': key, 'name': name})
        for i, f in enumerate(getattr(b, 'user_folders', []) or []):
            cats.append({'key': 'folder:%d' % i, 'name': f.name})
        return cats

    def _browser_root(self, cat):
        b = self._browser()
        if cat.startswith('color:'):
            return list(b.colors)[int(cat[6:])]
        if cat.startswith('folder:'):
            return list(b.user_folders)[int(cat[7:])]
        if cat not in dict(self.BROWSER_CATEGORIES):
            raise ValueError('unknown browser category %r' % cat)
        return getattr(b, cat)

    def _browser_item(self, cat, path):
        item = self._browser_root(cat)
        for i in path:
            item = list(item.children)[int(i)]
        return item

    def _browse_msg(self, cat, path):
        b = self._browser()
        msg = {'type': 'browse', 'cat': cat, 'path': path, 'name': '', 'items': [], 'truncated': False,
               'canPreview': hasattr(b, 'preview_item'), 'categories': []}
        if not cat:
            msg['categories'] = self._browser_categories()
            return msg
        item = self._browser_item(cat, path)
        msg['name'] = item.name
        children = list(item.children)
        msg['truncated'] = len(children) > self.BROWSER_LIMIT
        for child in children[:self.BROWSER_LIMIT]:
            msg['items'].append({
                'name': child.name,
                'isFolder': bool(child.is_folder),
                'isLoadable': bool(child.is_loadable),
                'isDevice': bool(getattr(child, 'is_device', False)),
            })
        return msg

    def _browser_load(self, msg):
        song = self._song()
        item = self._browser_item(msg['cat'], msg.get('path') or [])
        if not item.is_loadable:
            raise ValueError('%s cannot be loaded' % item.name)
        new_track = msg.get('target') == 'new'
        if new_track:
            # Place the new track after the selected one, like Live's own "insert MIDI track".
            sel = self._index_of_track(song.view.selected_track)
            index = sel + 1 if 0 <= sel < self._n_tracks else -1
            song.create_midi_track(index)
            song.view.selected_track = song.tracks[index if index >= 0 else len(song.tracks) - 1]
        elif msg.get('t', -1) >= 0:
            song.view.selected_track = self._tracks[int(msg['t'])]
        self._browser().load_item(item)
        track = song.view.selected_track
        t = next((i for i, tr in enumerate(song.tracks) if tr == track), -1)
        return {'type': 'loaded', 'name': item.name, 'track': track.name, 't': t, 'newTrack': new_track}

    # ── Parameter locks (Elektron-style) ───────────────────────────────────
    # A lock lane is the sequencer clip's automation envelope for one parameter of the
    # focused device, written as constant steps: locked steps hold their value, the rest
    # hold the lane's base value. Live then plays it back sample-accurately.

    def _lock_device(self, msg):
        """Device named in the command (t + path); commands don't rely on the shared focus,
        which another connected client may have changed."""
        if 'path' in msg and msg.get('t', -1) >= 0:
            return self._resolve(int(msg['t']), list(msg['path']))
        if self._focus is None:
            raise ValueError('pick a device to lock')
        return self._focus

    def _lock_target(self, msg):
        clip = self._seq_clip()
        if clip is None:
            raise ValueError('p-locks need a MIDI clip in the sequencer')
        device = self._lock_device(msg)
        loc = self._locate(device)
        if loc is None or loc[0] != self._index_of_track(self._seq_track):
            raise ValueError("that device isn't on the sequencer's track")
        i = int(msg['i'])
        p = device.parameters[i]
        key = '%d:%d:%s:%d' % (loc[0], self._seq_s, loc[1], int(i))
        return clip, p, key, loc

    def _lock_read(self, clip, p, key, step):
        n = max(1, int(round((clip.loop_end - clip.loop_start) / step)))
        env = clip.automation_envelope(p)
        if env is None:
            return self._lock_base.get(key, p.value), [None] * n
        samples = [env.value_at_time(clip.loop_start + (k + 0.5) * step) for k in range(n)]
        base = self._lock_base.get(key)
        if base is None:
            # After a reload we don't know the base: take the most common step value.
            counts = {}
            for v in samples:
                r = round(v, 5)
                counts[r] = counts.get(r, 0) + 1
            base = max(counts.items(), key=lambda kv: kv[1])[0]
            self._lock_base[key] = base
        eps = (p.max - p.min) * 1e-4
        return base, [None if abs(v - base) <= eps else v for v in samples]

    def _lock_write(self, clip, p, base, values, step):
        clip.clear_envelope(p)
        if all(v is None for v in values):
            if p.is_enabled:
                p.value = base
            return
        env = clip.create_automation_envelope(p)
        for k, v in enumerate(values):
            env.insert_step(clip.loop_start + k * step, step, base if v is None else v)
        self._song().re_enable_automation()

    def _clamp(self, p, v):
        v = max(p.min, min(p.max, float(v)))
        return float(round(v)) if p.is_quantized else v

    def _lock_command(self, cmd, msg):
        i = int(msg['i'])
        step = float(msg.get('step', 0.25))
        clip, p, key, loc = self._lock_target(msg)
        base, values = self._lock_read(clip, p, key, step)
        if cmd == 'lock_set':
            k = int(msg['k'])
            if 0 <= k < len(values):
                v = msg.get('value')
                values[k] = None if v is None else self._clamp(p, v)
                self._lock_write(clip, p, base, values, step)
        elif cmd == 'lock_base':
            base = self._clamp(p, msg['value'])
            self._lock_base[key] = base
            self._lock_write(clip, p, base, values, step)
        elif cmd == 'lock_clear':
            clip.clear_envelope(p)
            self._lock_base.pop(key, None)
            base, values = p.value, [None] * len(values)
        return self._locks_msg(p, i, loc, base, values, step)

    def _locks_msg(self, p, i, loc, base, values, step):
        def disp(v):
            try:
                return p.str_for_value(v)
            except Exception:
                return ''
        return {'type': 'locks', 't': loc[0], 's': self._seq_s, 'path': loc[1], 'i': i,
                'name': p.name, 'base': base, 'baseDisplay': disp(base), 'step': step,
                'values': values, 'displays': [None if v is None else disp(v) for v in values]}

    def _lock_step_msg(self, device, k, step):
        """All locks on one step of a device (for hold-a-step-and-turn)."""
        locks = {}
        clip = self._seq_clip()
        if clip is not None and device is not None:
            loc = self._locate(device)
            if loc is not None:
                for i, p in enumerate(device.parameters):
                    if clip.automation_envelope(p) is None:
                        continue
                    key = '%d:%d:%s:%d' % (loc[0], self._seq_s, loc[1], i)
                    _, values = self._lock_read(clip, p, key, step)
                    if 0 <= k < len(values) and values[k] is not None:
                        locks[str(i)] = values[k]
        return {'type': 'lockstep', 'k': k, 'locks': locks}

    def _send_seqpos(self):
        if not self._clients:
            return
        clip = self._seq_clip()
        pos = -1.0
        if clip is not None and clip.is_playing and self._song().is_playing:
            pos = round(clip.playing_position, 4)
        if pos < 0 and self._seq_last_pos == pos:
            return
        self._seq_last_pos = pos
        self._broadcast({'type': 'seqpos', 'pos': pos})

    # ── Serialisation ───────────────────────────────────────────────────────

    def _song_info(self):
        song = self._song()
        return {
            'tempo': song.tempo,
            'isPlaying': bool(song.is_playing),
            'metronome': bool(song.metronome),
            'sigNum': song.signature_numerator,
            'sigDen': song.signature_denominator,
            'sessionRecord': bool(song.session_record),
            'recordMode': bool(song.record_mode),
            'canUndo': bool(song.can_undo),
            'canRedo': bool(song.can_redo),
            'rootNote': int(getattr(song, 'root_note', 0)),
            'scaleName': str(getattr(song, 'scale_name', 'Major')),
            'scaleIntervals': [int(i) for i in getattr(song, 'scale_intervals', (0, 2, 4, 5, 7, 9, 11))],
        }

    def _slot_info(self, slot):
        info = {'hasClip': False, 'name': '', 'color': 0, 'state': 'empty',
                'hasStop': bool(slot.has_stop_button), 'isGroupSlot': False}
        if slot.has_clip:
            clip = slot.clip
            info['hasClip'] = True
            info['name'] = clip.name
            info['color'] = _color(clip)
            if clip.is_recording:
                info['state'] = 'recording'
            elif clip.is_triggered:
                info['state'] = 'triggered'
            elif clip.is_playing:
                info['state'] = 'playing'
            else:
                info['state'] = 'stopped'
        elif slot.controls_other_clips:
            info['isGroupSlot'] = True
            status = slot.playing_status
            if slot.is_triggered:
                info['state'] = 'triggered'
            elif status == 1:
                info['state'] = 'playing'
            elif status == 2:
                info['state'] = 'recording'
            else:
                info['state'] = 'stopped'
        elif slot.is_triggered:
            info['state'] = 'triggered'
        return info

    def _track_info(self, t, track, with_slots=False):
        kind = self._kind(t)
        mixer = track.mixer_device
        info = {
            'i': t, 'kind': kind, 'name': track.name, 'color': _color(track),
            'volume': mixer.volume.value, 'volumeStr': _pstr(mixer.volume),
            'pan': mixer.panning.value, 'panStr': _pstr(mixer.panning),
            'sends': [p.value for p in mixer.sends],
            'mute': False, 'solo': False, 'arm': False, 'canArm': False,
            'isGroup': False, 'isFolded': False, 'groupIndex': -1,
            'playingSlot': -1, 'firedSlot': -1, 'midi': False,
            'devices': [{'name': d.name, 'className': d.class_name, 'isActive': bool(d.is_active)}
                        for d in track.devices],
        }
        if kind != 'master':
            info['mute'] = bool(track.mute)
            info['solo'] = bool(track.solo)
        if kind == 'track':
            info['canArm'] = bool(track.can_be_armed)
            if track.can_be_armed:
                info['arm'] = bool(track.arm)
            info['isGroup'] = bool(track.is_foldable)
            if track.is_foldable:
                info['isFolded'] = bool(track.fold_state)
            if track.is_grouped:
                info['groupIndex'] = self._index_of_track(track.group_track)
            info['playingSlot'] = track.playing_slot_index
            info['firedSlot'] = track.fired_slot_index
            info['midi'] = bool(getattr(track, 'has_midi_input', False))
            if with_slots:
                info['slots'] = [self._slot_info(s) for s in track.clip_slots]
        elif with_slots:
            info['slots'] = []
        return info

    def _scene_info(self, scene):
        return {'name': scene.name, 'color': _color(scene),
                'triggered': bool(scene.is_triggered)}

    def _state_msg(self):
        song = self._song()
        return {
            'type': 'state',
            'song': self._song_info(),
            'tracks': [self._track_info(t, tr, with_slots=True) for t, tr in enumerate(self._tracks)],
            'scenes': [self._scene_info(s) for s in song.scenes],
            'returns': [r.name for r in song.return_tracks],
        }

    def _device_tree(self, track):
        out = []

        def walk(devices, prefix, depth, chain_name):
            for i, d in enumerate(devices):
                path = prefix + [i]
                out.append({
                    'path': path, 'name': d.name, 'className': d.class_name,
                    'depth': depth, 'isActive': bool(d.is_active),
                    'isRack': bool(d.can_have_chains),
                    'chain': chain_name if i == 0 else '',
                })
                if d.can_have_chains:
                    for ci, chain in enumerate(d.chains):
                        walk(chain.devices, path + [ci], depth + 1, chain.name)
        walk(track.devices, [], 0, '')
        return out

    def _devices_msg(self):
        if self._watch is None:
            return {'type': 'devices', 't': -1, 'devices': []}
        return {'type': 'devices', 't': self._index_of_track(self._watch),
                'devices': self._device_tree(self._watch)}

    def _device_msg(self):
        loc = self._locate(self._focus) if self._focus is not None else None
        if loc is None:
            return {'type': 'device', 't': -1, 'path': [], 'name': '', 'className': '', 'params': []}
        d = self._focus
        params = []
        for i, p in enumerate(d.parameters):
            quantized = bool(p.is_quantized)
            params.append({
                'i': i, 'name': p.name, 'value': p.value, 'min': p.min, 'max': p.max,
                'quantized': quantized,
                'items': list(p.value_items) if quantized else [],
                'display': _pstr(p), 'enabled': bool(p.is_enabled),
            })
        return {'type': 'device', 't': loc[0], 'path': loc[1], 'name': d.name,
                'className': d.class_name, 'params': params}

    def _appointed_msg(self):
        d = self._song().appointed_device
        loc = self._locate(d) if d is not None else None
        if loc is None:
            return {'type': 'appointed', 't': -1, 'path': []}
        return {'type': 'appointed', 't': loc[0], 'path': loc[1]}

    # ── Lookup ──────────────────────────────────────────────────────────────

    def _index_of_track(self, track):
        for i, tr in enumerate(self._tracks):
            try:
                if tr == track:
                    return i
            except Exception:
                pass
        return -1

    def _resolve(self, t, path):
        d = self._tracks[t].devices[path[0]]
        rest = path[1:]
        while len(rest) >= 2:
            d = d.chains[rest[0]].devices[rest[1]]
            rest = rest[2:]
        return d

    def _locate(self, device):
        """Return (track_index, path) for a device, or None."""
        def walk(devices, prefix):
            for i, d in enumerate(devices):
                path = prefix + [i]
                try:
                    if d == device:
                        return path
                except Exception:
                    pass
                if d.can_have_chains:
                    for ci, chain in enumerate(d.chains):
                        found = walk(chain.devices, path + [ci])
                        if found:
                            return found
            return None
        try:
            for t, track in enumerate(self._tracks):
                found = walk(track.devices, [])
                if found:
                    return (t, found)
        except Exception:
            pass
        return None

    # ── Commands ────────────────────────────────────────────────────────────

    def _handle(self, c, msg):
        cmd = msg.get('cmd')
        song = self._song()

        if cmd == 'get_state':
            self._send(c, self._state_msg())
        elif cmd == 'fire_clip':
            self._tracks[msg['t']].clip_slots[msg['s']].fire()
        elif cmd == 'stop_clip':
            self._tracks[msg['t']].clip_slots[msg['s']].stop()
        elif cmd == 'stop_track':
            self._tracks[msg['t']].stop_all_clips()
        elif cmd == 'fire_scene':
            song.scenes[msg['s']].fire()
        elif cmd == 'stop_all':
            song.stop_all_clips()
        elif cmd == 'play':
            song.start_playing()
        elif cmd == 'continue':
            song.continue_playing()
        elif cmd == 'stop':
            song.stop_playing()
        elif cmd == 'tempo':
            song.tempo = max(20.0, min(999.0, float(msg['value'])))
        elif cmd == 'tap_tempo':
            song.tap_tempo()
        elif cmd == 'metronome':
            song.metronome = bool(msg['on'])
        elif cmd == 'session_record':
            song.session_record = bool(msg['on'])
        elif cmd == 'undo':
            if song.can_undo:
                song.undo()
        elif cmd == 'redo':
            if song.can_redo:
                song.redo()
        elif cmd == 'set_track':
            self._set_track(msg)
        elif cmd == 'select_track':
            song.view.selected_track = self._tracks[msg['t']]
        elif cmd == 'watch_track':
            t = msg.get('t', -1)
            self._watch = self._tracks[t] if 0 <= t < len(self._tracks) else None
            self._listen_tree()
            self._send(c, self._devices_msg())
        elif cmd == 'focus_device':
            t, path = msg.get('t', -1), msg.get('path') or []
            self._focus = self._resolve(t, path) if (t >= 0 and path) else None
            self._listen_focus()
            self._send(c, self._device_msg())
        elif cmd == 'select_device':
            song.view.select_device(self._resolve(msg['t'], msg['path']))
        elif cmd == 'toggle_device':
            d = self._resolve(msg['t'], msg['path'])
            on = d.parameters[0]
            on.value = on.min if on.value > on.min else on.max
        elif cmd == 'set_param':
            if self._focus is None:
                return
            p = self._focus.parameters[msg['i']]
            v = max(p.min, min(p.max, float(msg['value'])))
            if p.is_quantized:
                v = round(v)
            if p.is_enabled:
                p.value = v
        elif cmd == 'set_scale':
            if 'root' in msg:
                song.root_note = int(msg['root']) % 12
            if 'name' in msg:
                song.scale_name = str(msg['name'])
        elif cmd == 'instrument_track':
            self._set_instrument(msg.get('t', -1))
            self._broadcast(self._instrument_msg())
        elif cmd == 'seq_watch':
            self._seq_watch(msg.get('t', -1), msg.get('s', -1))
            self._send(c, self._seq_msg())
        elif cmd == 'seq_toggle':
            self._seq_toggle(msg)
        elif cmd == 'seq_clear_row':
            clip = self._seq_clip()
            if clip is not None:
                clip.remove_notes_extended(int(msg['pitch']), 1, 0.0, 1e6)
        elif cmd == 'seq_length':
            self._seq_length(float(msg['length']))
        elif cmd == 'seq_double':
            clip = self._seq_clip()
            if clip is not None:
                clip.duplicate_loop()
        elif cmd in ('lock_lane', 'lock_set', 'lock_base', 'lock_clear'):
            self._send(c, self._lock_command(cmd, msg))
        elif cmd == 'lock_step':
            self._send(c, self._lock_step_msg(self._lock_device(msg), int(msg['k']), float(msg['step'])))
        elif cmd == 'browse':
            self._send(c, self._browse_msg(msg.get('cat'), msg.get('path') or []))
        elif cmd == 'browser_load':
            self._send(c, self._browser_load(msg))
        elif cmd == 'browser_preview':
            b = self._browser()
            if msg.get('stop'):
                if hasattr(b, 'stop_preview'):
                    b.stop_preview()
            elif hasattr(b, 'preview_item'):
                b.preview_item(self._browser_item(msg['cat'], msg.get('path') or []))
        elif cmd == 'dev_reload':
            # Picked up by the host wrapper in __init__.py after this tick.
            self.reload_requested = True
        elif cmd == 'ping':
            self._send(c, {'type': 'pong'})
        else:
            raise ValueError('unknown cmd %r' % cmd)

    def _set_track(self, msg):
        track = self._tracks[msg['t']]
        mixer = track.mixer_device
        if 'mute' in msg:
            track.mute = bool(msg['mute'])
        if 'solo' in msg:
            track.solo = bool(msg['solo'])
        if 'arm' in msg and getattr(track, 'can_be_armed', False):
            track.arm = bool(msg['arm'])
        if 'fold' in msg and getattr(track, 'is_foldable', False):
            track.fold_state = bool(msg['fold'])
        if 'volume' in msg:
            p = mixer.volume
            p.value = max(p.min, min(p.max, float(msg['volume'])))
        if 'pan' in msg:
            p = mixer.panning
            p.value = max(p.min, min(p.max, float(msg['pan'])))
        if 'send' in msg:
            p = mixer.sends[int(msg['send'])]
            p.value = max(p.min, min(p.max, float(msg['value'])))
