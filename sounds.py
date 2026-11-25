"""Synthesizes the meter's sounds so the app ships no borrowed audio.
tick (cent), bell (dollar), feed (receipt printing), flag (trip starts).  Usage: python3 sounds.py <out_dir>"""
import math, random, struct, sys, wave

RATE = 44100

def write(path, samples):
    peak = max(abs(s) for s in samples) or 1
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s / peak * 0.8 * 32767)) for s in samples))

def tick():
    random.seed(7)
    n = int(RATE * 0.045)
    return [(random.uniform(-1, 1) * math.exp(-t / 0.0016) + 0.6 * math.sin(2 * math.pi * 2100 * t) * math.exp(-t / 0.008))
            for t in (i / RATE for i in range(n))]

def bell():
    n = int(RATE * 1.1)
    partials = [(1568, 1.0, 0.45), (3136, 0.45, 0.30), (4704, 0.28, 0.18), (6272, 0.12, 0.10)]
    return [sum(a * math.sin(2 * math.pi * f * t) * math.exp(-t / d) for f, a, d in partials) * min(1, t / 0.002)
            for t in (i / RATE for i in range(n))]

def feed():
    """Thermal printer: stepper-motor clicks at 240/s over a low motor hum, 1.4 s."""
    random.seed(11)
    n, step = int(RATE * 1.4), RATE // 240
    out = []
    for i in range(n):
        t, k = i / RATE, (i % step) / RATE
        env = min(1, t / 0.04) * min(1, (1.4 - t) / 0.08)
        out.append(env * (random.uniform(-1, 1) * math.exp(-k / 0.0007) * 0.7
                          + 0.25 * math.sin(2 * math.pi * 118 * t) + 0.12 * math.sin(2 * math.pi * 236 * t)))
    return out

def flag():
    """The meter flag swinging down: a low thump, a latch click, a short spring ring."""
    random.seed(3)
    n = int(RATE * 0.35)
    return [(math.sin(2 * math.pi * 85 * t) * math.exp(-t / 0.05)
             + 0.8 * random.uniform(-1, 1) * math.exp(-max(0, t - 0.012) / 0.002) * (t >= 0.012)
             + 0.18 * math.sin(2 * math.pi * 940 * t) * math.exp(-t / 0.07)) * min(1, t / 0.001)
            for t in (i / RATE for i in range(n))]

out = sys.argv[1]
write(f"{out}/tick.wav", tick())
write(f"{out}/bell.wav", bell())
write(f"{out}/feed.wav", feed())
write(f"{out}/flag.wav", flag())
