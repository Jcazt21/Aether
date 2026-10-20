#!/usr/bin/env python3
"""S1: rebuild a native FLAC from Tidal DASH segments and compare PCM MD5 with STREAMINFO.
Usage: python3 Spikes/s1_dash_to_flac.py <track_id> <HI_RES_LOSSLESS|LOSSLESS> [api]"""
import base64, hashlib, html, json, re, struct, subprocess, sys, urllib.request
from pathlib import Path

track_id, quality = sys.argv[1], sys.argv[2]
api = sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:8000"
out = Path(__file__).parent / "out"
out.mkdir(exist_ok=True)

def get(url):
    return urllib.request.urlopen(url, timeout=30).read()

info = json.loads(get(f"{api}/track/?id={track_id}&quality={quality}"))["data"]
print("playbackinfo:", {k: v for k, v in info.items() if k != "manifest"})
mpd = base64.b64decode(info["manifest"]).decode()
init_url = html.unescape(re.search(r'initialization="([^"]+)"', mpd).group(1))
media = html.unescape(re.search(r'media="([^"]+)"', mpd).group(1))
timeline = re.findall(r'<S d="(\d+)"(?: r="(\d+)")?/>', mpd)
durations = [int(d) for d, r in timeline for _ in range(int(r or 0) + 1)]
print("segments:", len(durations), "timeline samples:", sum(durations))

def find(b, path, off=0, end=None):
    end = len(b) if end is None else end
    while off + 8 <= end:
        size, typ = struct.unpack(">I4s", b[off:off + 8])
        typ = typ.decode("latin1")
        if typ == path[0]:
            if len(path) == 1:
                return off, size
            skip = {"stsd": 16, "fLaC": 36}.get(typ, 8)
            return find(b, path[1:], off + skip, off + size)
        off += size
    return None

init = get(init_url)
(out / "init.mp4").write_bytes(init)
o, s = find(init, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"])
blocks = init[o + 12:o + s]
si = blocks[4:38]
packed = int.from_bytes(si[10:18], "big")
rate, ch, bps = packed >> 44, ((packed >> 41) & 7) + 1, ((packed >> 36) & 31) + 1
total, md5 = packed & 0xFFFFFFFFF, si[18:34].hex()
print(f"STREAMINFO rate={rate} ch={ch} bps={bps} total={total} md5={md5}")

flac = bytearray(b"fLaC" + blocks)
for n in range(1, len(durations) + 1):
    seg = get(media.replace("$Number$", str(n)))
    if n == 1:
        (out / "seg1.m4s").write_bytes(seg)
    off = 0
    while off < len(seg):
        size, typ = struct.unpack(">I4s", seg[off:off + 8])
        if typ == b"mdat":
            flac += seg[off + 8:off + size]
        off += size
path = out / f"{track_id}_{quality}.flac"
path.write_bytes(flac)
print("wrote", path, len(flac), "bytes")

wav = out / f"{track_id}_{quality}.wav"
fmt = "LEI16" if bps == 16 else "LEI24"
subprocess.run(["afconvert", "-f", "WAVE", "-d", fmt, str(path), str(wav)], check=True)
w = wav.read_bytes()
off = 12
while off < len(w):
    cid, size = struct.unpack("<4sI", w[off:off + 8])
    if cid == b"data":
        pcm = w[off + 8:off + 8 + size]
        break
    off += 8 + size + (size & 1)
actual = hashlib.md5(pcm).hexdigest()
frames = len(pcm) // (ch * bps // 8)
print(f"decoded frames={frames} expected={total} md5={actual}")
print("S1 VERDICT:", "PASS" if actual == md5 and frames == total == sum(durations) else "FAIL")
