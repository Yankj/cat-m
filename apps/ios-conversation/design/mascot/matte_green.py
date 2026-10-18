"""Green-screen mascot clip -> 96px RGBA PNG frames (seamless: drops last frame == first).
usage: python3 matte.py <pose> <clip.mp4> [outdir] [--pingpong]
--pingpong: for clips whose end != start: every 2nd frame forward, then reversed (≈ same length)."""
import sys, os, glob, subprocess, tempfile
from PIL import Image
import numpy as np
pp='--pingpong' in sys.argv; args=[a for a in sys.argv[1:] if a!='--pingpong']
pose, clip = args[0], args[1]; out = args[2] if len(args) > 2 else f'alpha/{pose}'
S = 96
os.makedirs(out, exist_ok=True); [os.remove(f) for f in glob.glob(f'{out}/*.png')]
tmp = tempfile.mkdtemp()
subprocess.run(['ffmpeg','-v','error','-y','-i',clip,'-map','0:v:0',f'{tmp}/%03d.png'],check=True)
frames = sorted(glob.glob(f'{tmp}/*.png'))
if pp:
    fw = frames[::2]; frames = fw + fw[-2:0:-1]
else:
    frames = frames[:-1]
for n,f in enumerate(frames,1):
    a=np.asarray(Image.open(f).convert('RGB')).astype(float)
    r,g,b=a[...,0],a[...,1],a[...,2]
    al=1-np.clip((g-np.maximum(r,b)-15)/70,0,1)
    g2=np.minimum(g,np.maximum(r*0.85,b))
    pm=np.dstack([np.dstack([r,g2,b])*al[...,None],al*255]).astype(np.uint8)
    Image.fromarray(pm,'RGBa').resize((S,S),Image.LANCZOS).convert('RGBA').save(f'{out}/{n:03d}.png')
print(pose,len(frames),'frames ->',out)
