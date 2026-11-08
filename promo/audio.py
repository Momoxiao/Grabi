import math, struct, wave, random
SR = 44100
DUR = 47.0
random.seed(7)
N = int(SR*DUR)
buf = [0.0]*N

def add(t, f, amp, dur, wave_type='sine', pan=0.0):
    if t < 0: return
    i0 = int(t*SR)
    n = int(dur*SR)
    for k in range(n):
        i = i0+k
        if i >= N: break
        x = k/SR
        env = min(1.0, x/0.05) * math.exp(-x*1.6) if dur < 3 else min(1.0, x/0.6) * min(1.0,(dur-x)/0.9)
        if env < 0: env = 0
        if wave_type=='sine': s = math.sin(2*math.pi*f*x)
        elif wave_type=='tri':
            p = (f*x) % 1.0
            s = 4*abs(p-0.5)-1
        else:
            s = 2*((f*x)%1.0)-1
        buf[i] += s*amp*env*(1.0 if pan==0 else 1.0)

def pad(t, freq, amp, dur):
    i0=int(t*SR); n=int(dur*SR)
    for k in range(n):
        i=i0+k
        if i>=N: break
        x=k/SR
        env = min(1.0,x/1.2)*min(1.0,max(0.0,(dur-x)/1.2))
        s = (math.sin(2*math.pi*freq*x)*0.6
             + math.sin(2*math.pi*freq*1.5*x)*0.25
             + math.sin(2*math.pi*freq*2.01*x)*0.15)
        buf[i] += s*amp*env

# --- chord pads, one per scene group (warm minor progression) ---
A3, C4, E4, G4 = 220.0, 261.63, 329.63, 392.0
F3, A3b, C4b, E4b = 174.61, 207.65, 261.63, 311.13
G3, B3, D4, F4 = 196.0, 246.94, 293.66, 349.23
E3, G3b, B3b, D4b = 164.81, 196.0, 246.94, 293.66

chords = [
 (0.2, 7.2, [A3,C4,E4,G4]),
 (7.4, 4.2, [F3,A3b,C4b,E4b]),
 (11.6,5.2, [G3,B3,D4,F4]),
 (16.8,9.0, [A3,C4,E4,G4]),
 (25.4,9.2, [F3,A3b,C4b,E4b]),
 (34.6,13.2,[G3,B3,D4,F4]),
]
for t,d,notes in chords:
    for f in notes:
        pad(t, f, 0.035, d)

# --- sparkle accents at feature beats ---
for t,d,f in [(3.7,0.9,880),(7.5,0.8,1046.5),(11.7,0.9,659.3),
              (16.9,1.0,783.99),(21.1,0.9,880),(25.5,1.0,987.77),
              (29.9,1.0,1046.5),(34.7,1.0,1174.7),(39.1,1.1,880),
              (43.1,1.6,1318.5)]:
    add(t,f,0.05,d,'sine')

# --- soft kick pulse per beat (subtle, 96bpm) ---
beat = 60/96
t = 0.35
while t < DUR-0.6:
    i0=int(t*SR); n=int(0.16*SR)
    for k in range(n):
        i=i0+k
        if i>=N: break
        x=k/SR
        env=math.exp(-x*26)
        buf[i]+= math.sin(2*math.pi*(52+34*math.exp(-x*40))*x)*0.10*env
    t += beat

# --- riser into each scene change ---
for t in [6.6,10.9,15.9,20.2,24.6,29.0,33.8,38.2,42.2]:
    n=int(0.55*SR); i0=int(t*SR)
    for k in range(n):
        i=i0+k
        if i>=N: break
        x=k/SR
        env=(x/0.55)**2
        buf[i]+= (random.random()*2-1)*0.030*env

# normalize / soft clip
peak=max(abs(v) for v in buf) or 1.0
gain=0.72/peak
out=[]
for v in buf:
    s=math.tanh(v*gain*1.25)
    out.append(int(max(-1,min(1,s))*32767))

import os
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'score.wav')
w=wave.open(out_path,'wb')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
w.writeframes(b''.join(struct.pack('<h',v) for v in out))
w.close()
print('wrote', out_path, DUR, 's')
