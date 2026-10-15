#!/usr/bin/env python3
"""r11 brand renderer: launch glow/paw layers + AppIcon (light/dark/tinted). Same geometry as PawMark (24-unit grid).
Usage: python3 render_brand.py <Assets.xcassets>"""
import sys, os, json, random
from PIL import Image, ImageDraw, ImageFilter, ImageChops
PADS=[(8.3,16.9,3.3,3.9),(15.7,16.9,3.3,3.9),(12,15.9,4.7,5.3),(4.9,9.7,2.5,2.7),(9.3,5.3,2.6,2.9),(14.7,5.3,2.6,2.9),(19.1,9.7,2.5,2.7)]
def hx(h,a=255): h=h.lstrip('#'); return (int(h[0:2],16),int(h[2:4],16),int(h[4:6],16),a)
CANVAS=hx('F28650'); GLOW=hx('FFC29C')
CREAM=(hx('FFFFFF'),hx('FFF4EC'),hx('F3C4A6')); CLAY=(hx('FFB48A'),hx('F5843F'),hx('E0652A'))
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(4))
def radial(size,center,radius,stops):
    w,h=size; img=Image.new('RGBA',size); px=img.load(); cx,cy=center
    for y in range(h):
        for x in range(w):
            t=min(1.0,((x-cx)**2+(y-cy)**2)**0.5/radius)
            for i in range(len(stops)-1):
                (o0,c0),(o1,c1)=stops[i],stops[i+1]
                if t<=o1: px[x,y]=lerp(c0,c1,(t-o0)/(o1-o0) if o1>o0 else 0); break
    return img
def radial_fast(size,center,radius,stops,ss=8):
    w,h=size; small=radial((max(1,w//ss),max(1,h//ss)),(center[0]/ss,center[1]/ss),radius/ss,stops)
    return small.resize(size,Image.BICUBIC)
def paw(px,palette,shadow=True,spec=True,only=None):
    """Return RGBA image px*px with the paw in a 24-unit box."""
    S=4; W=px*S; u=W/24; img=Image.new('RGBA',(W,W),(0,0,0,0))
    if shadow:
        sh=Image.new('RGBA',(W,W),(0,0,0,0)); d=ImageDraw.Draw(sh)
        d.ellipse([ (12-7)*u,(22.2-1.3)*u,(12+7)*u,(22.2+1.3)*u ],fill=(138,58,18,80))
        img=Image.alpha_composite(img,sh.filter(ImageFilter.GaussianBlur(u*0.9)))
    hi,base,rim=palette
    for pi,(cx,cy,rx,ry) in enumerate(PADS):
        if only is not None and pi not in only: continue
        box=(int((cx-rx)*u),int((cy-ry)*u),int((cx+rx)*u),int((cy+ry)*u)); bw,bh=box[2]-box[0],box[3]-box[1]
        # soft drop under each pad (jelly depth)
        dep=Image.new('RGBA',(W,W),(0,0,0,0)); ImageDraw.Draw(dep).ellipse([box[0],box[1]+u*0.35,box[2],box[3]+u*0.35],fill=rim[:3]+(110,))
        img=Image.alpha_composite(img,dep.filter(ImageFilter.GaussianBlur(u*0.25)))
        g=radial_fast((bw,bh),(bw*0.36,bh*0.3),max(bw,bh)*1.05,[(0,hi),(0.55,base),(1,rim)],ss=4)
        m=Image.new('L',(bw,bh),0); ImageDraw.Draw(m).ellipse([0,0,bw-1,bh-1],fill=255)
        layer=Image.new('RGBA',(W,W),(0,0,0,0)); layer.paste(g,box[:2],m); img=Image.alpha_composite(img,layer)
        if spec and pi>=2:
            sp=Image.new('RGBA',(W,W),(0,0,0,0)); sx,sy=cx-rx*0.38,cy-ry*0.45
            ImageDraw.Draw(sp).ellipse([(sx-rx*0.32)*u,(sy-ry*0.2)*u,(sx+rx*0.32)*u,(sy+ry*0.2)*u],fill=(255,255,255,150))
            img=Image.alpha_composite(img,sp.filter(ImageFilter.GaussianBlur(u*0.22)))
    return img.resize((px,px),Image.LANCZOS)
def dither(img,amt=2):
    random.seed(7); n=Image.effect_noise(img.size,amt*8).convert('L'); n=n.point(lambda v:128+(v-128)//4)
    r,g,b,a=img.split(); f=lambda c:ImageChops.add(c,n,1,-128)
    return Image.merge('RGBA',(f(r),f(g),f(b),a))
def glow(pt,scale):
    px=pt*scale; return radial_fast((px,px),(px/2,px*0.47),px/2,[(0,GLOW),(0.45,lerp(GLOW,CANVAS,0.55)),(1,CANVAS)],ss=6)
P3=open('/System/Library/ColorSync/Profiles/Display P3.icc','rb').read()
# The system launch screen composites in Display P3; tag launch layers (and LaunchCanvas) as P3 so SwiftUI frame 0 matches.
def imageset(root,name,files):
    d=os.path.join(root,name+'.imageset'); os.makedirs(d,exist_ok=True)
    for f in os.listdir(d): os.remove(os.path.join(d,f))
    imgs=[]
    for scale,im in files: fn=f'{name}@{scale}x.png'; im.save(os.path.join(d,fn),optimize=True,icc_profile=P3); imgs.append({'filename':fn,'idiom':'universal','scale':f'{scale}x'})
    imgs.insert(0,{'idiom':'universal','scale':'1x'})
    json.dump({'images':imgs,'info':{'author':'xcode','version':1}},open(os.path.join(d,'Contents.json'),'w'),indent=1)
GLOW_PT=760; PAW_PT=160
def main(root):
    for name in ('LaunchPaw',): 
        p=os.path.join(root,name+'.imageset')
    sets={'LaunchGlow':[],'LaunchPawMark':[],'LaunchPaw':[]}
    for s in (2,3):
        g=glow(GLOW_PT,s)
        # LaunchPawMark is literally the composite of the animated part layers, so frame 0 == static launch paw.
        pm=paw(PAW_PT*s,CREAM,shadow=True,only=[0,1,2])
        for t in range(4): pm.alpha_composite(paw(PAW_PT*s,CREAM,shadow=False,only=[3+t]))
        comb=g.copy(); o=(GLOW_PT*s-PAW_PT*s)//2; comb.alpha_composite(pm,(o,o))
        sets['LaunchGlow'].append((s,g)); sets['LaunchPawMark'].append((s,pm)); sets['LaunchPaw'].append((s,comb))
    # r11b: per-part layers for the in-place jelly motion (same 160pt canvas, composite == LaunchPawMark)
    parts={'LaunchPawPad':dict(shadow=True,only=[0,1,2])}
    for t in range(4): parts[f'LaunchPawToe{t}']=dict(shadow=False,only=[3+t])
    for name,kw in parts.items(): sets[name]=[(s,paw(PAW_PT*s,CREAM,**kw)) for s in (2,3)]
    for k,v in sets.items(): imageset(root,k,v)
    c=CANVAS
    json.dump({'colors':[{'color':{'color-space':'display-p3','components':{'alpha':'1.000','red':f'0x{c[0]:02X}','green':f'0x{c[1]:02X}','blue':f'0x{c[2]:02X}'}},'idiom':'universal'}],'info':{'author':'xcode','version':1}},open(os.path.join(root,'LaunchCanvas.colorset','Contents.json'),'w'),indent=1)
    # AppIcon
    d=os.path.join(root,'AppIcon.appiconset')
    for f in os.listdir(d): os.remove(os.path.join(d,f))
    N=1024
    light=radial_fast((N,N),(N*0.42,N*0.36),N*0.95,[(0,hx('FFC9A6')),(0.5,hx('F7955E')),(1,hx('E8662C'))]); light.alpha_composite(paw(640,CREAM),(192,214))
    dark=radial_fast((N,N),(N*0.5,N*0.4),N*0.8,[(0,hx('3A2418')),(1,hx('140E0B'))]); dark.alpha_composite(paw(640,CLAY),(192,214))
    tint=Image.new('RGBA',(N,N),(0,0,0,255)); tp=paw(640,(hx('FFFFFF'),hx('E6E6E6'),hx('9A9A9A'))); tint.alpha_composite(tp,(192,214)); tint=tint.convert('L').convert('RGB')
    dither(light).convert('RGB').save(os.path.join(d,'AppIcon-light.png')); dark.convert('RGB').save(os.path.join(d,'AppIcon-dark.png')); tint.save(os.path.join(d,'AppIcon-tinted.png'))
    json.dump({'images':[{'filename':'AppIcon-light.png','idiom':'universal','platform':'ios','size':'1024x1024'},
      {'appearances':[{'appearance':'luminosity','value':'dark'}],'filename':'AppIcon-dark.png','idiom':'universal','platform':'ios','size':'1024x1024'},
      {'appearances':[{'appearance':'luminosity','value':'tinted'}],'filename':'AppIcon-tinted.png','idiom':'universal','platform':'ios','size':'1024x1024'}],
      'info':{'author':'xcode','version':1}},open(os.path.join(d,'Contents.json'),'w'),indent=1)
if __name__=='__main__': main(sys.argv[1])
