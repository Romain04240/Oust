#!/usr/bin/env python3
"""Motifs Oust originaux, synthèse déterministe sans échantillon tiers (GPL-3.0)."""
import math, wave, struct
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'App/Oust/Sounds'
root.mkdir(exist_ok=True)
for name, notes in {'connect': [523.25, 783.99], 'disconnect': [783.99, 523.25],
                    'warning': [659.25, 622.25, 493.88], 'charged': [523.25, 659.25, 1046.5]}.items():
    frames=[]
    rate=44100
    for frequency in notes:
        duration=.22
        for i in range(round(duration*rate)):
            t=i/rate
            envelope=(1-math.exp(-t*120))*math.exp(-t*18)
            value=.22*envelope*(math.sin(2*math.pi*frequency*t)+.18*math.sin(4*math.pi*frequency*t))
            frames.append(struct.pack('<h', round(max(-1,min(1,value))*32767)))
    with wave.open(str(root/f'oust-{name}-v1.wav'), 'wb') as audio:
        audio.setparams((1,2,rate,0,'NONE','not compressed'))
        audio.writeframes(b''.join(frames))
