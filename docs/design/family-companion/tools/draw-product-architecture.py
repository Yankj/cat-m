#!/usr/bin/env python3
"""Render cat product architecture overview, v0.1. Requires matplotlib + Noto CJK."""
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle
from matplotlib.font_manager import FontProperties

OUT = Path(__file__).resolve().parent
W, H = 1680, 2260
C = dict(bg='#FAFAF8', white='#FFFFFF', ink='#282A28', muted='#727671', line='#DADDD7', sage='#E9EBE6', green='#7D827A', pale='#F0F1ED', amber='#E3E3DC')
REG = FontProperties(fname='/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
BOLD = FontProperties(fname='/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc')
plt.rcParams['svg.fonttype'] = 'path'
plt.rcParams['pdf.fonttype'] = 3
fig = plt.figure(figsize=(16.8,22.6), facecolor=C['bg'])
ax = fig.add_axes([0,0,1,1]); ax.set_xlim(0,W); ax.set_ylim(H,0); ax.axis('off')

def box(x,y,w,h,fill='white',stroke='line',r=18,dashed=False,lw=1.5):
 p=FancyBboxPatch((x,y),w,h,boxstyle=f'round,pad=0,rounding_size={r}',facecolor=C.get(fill,fill),edgecolor=C.get(stroke,stroke),linewidth=lw,linestyle=(0,(6,5)) if dashed else '-',zorder=1)
 ax.add_patch(p); return p

def txt(x,y,s,size=26,bold=False,color='ink',ha='left',va='center',ls=1.55):
 return ax.text(x,y,s,fontproperties=BOLD if bold else REG,fontsize=size*.72,color=C.get(color,color),ha=ha,va=va,linespacing=ls,zorder=4)

def line(x1,y1,x2,y2,c='line',lw=1.5,style='-'):
 ax.plot([x1,x2],[y1,y2],color=C.get(c,c),lw=lw,linestyle=style,zorder=2)

def arrow(x1,y1,x2,y2,c='green',style='-|>',lw=1.8,connectionstyle='arc3'):
 ax.add_patch(FancyArrowPatch((x1,y1),(x2,y2),arrowstyle=style,mutation_scale=13,color=C.get(c,c),linewidth=lw,connectionstyle=connectionstyle,zorder=2))

def section(y,n,title,sub=None):
 txt(80,y,n,23,True,'green')
 txt(133,y,title,32,True)
 if sub: txt(1600,y,sub,22,False,'muted',ha='right')

def bullet(x,y,s,size=27):
 ax.add_patch(Circle((x+4,y),3.5,color=C['green']))
 txt(x+22,y,s,size)

# Header: product promise first, execution status visibly separate.
txt(80,78,'cat',43,True)
txt(175,78,'PRODUCT ARCHITECTURE',18,True,'muted')
box(1300,50,300,56,'pale','pale',r=28)
txt(1450,78,'产品方案 v0.1 · 待评审',22,False,'ink',ha='center')
txt(80,157,'理解这个家，',55,True)
txt(80,225,'陪家长把生活和成长照顾好',55,True)
line(80,274,1600,274)

# Audience road map: future is explicitly dashed and not part of phase one.
box(80,306,850,110,'sage','sage')
txt(107,337,'首期人群',21,True,'muted')
txt(107,380,'宝妈带孩子',34,True)
txt(387,380,'围绕生活与成长，给家长持续支持',25,False,'ink')
box(954,306,646,110,'bg','green',dashed=True)
txt(982,337,'后续扩展 · 不纳入首期',21,True,'muted')
txt(982,380,'家庭事务  /  自我管理',31,True)

# Three user-facing navigation surfaces.
section(473,'01','三个入口，连接日常与长期')
cardw=490
for i,(title,subtitle,items) in enumerate([
 ('今天','现在要关注什么',['近期安排','待决定','有依据的提醒']),
 ('聊聊','把事情商量清楚',['文字 / 语音 / 图片','澄清与确认','结构化行动']),
 ('我们家','沉淀共同的家庭背景',['成员协作','成长计划','可纠正的家庭记忆'])]):
 x=80+i*515
 box(x,512,cardw,275)
 box(x+26,539,50,50,'sage','sage',r=14)
 txt(x+51,564,f'{i+1:02}',22,True,ha='center')
 txt(x+96,564,title,37,True)
 txt(x+26,616,subtitle,24,False,'muted')
 for j,it in enumerate(items): bullet(x+28,667+j*42,it,28)

box(80,814,1520,114,'pale','pale')
txt(107,847,'共用的生活与成长场景',23,True,'muted')
txt(107,892,'学业   ·   补习   ·   运动   ·   成长规划   ·   择校   ·   衣食住行',31,True)
arrow(840,940,840,974)

# Five-step loop, including visible feedback path rather than a task funnel.
section(1007,'02','持续陪伴的核心循环','不是打卡评分，也不以完成率定义成长')
box(80,1047,1520,245,'sage','sage')
loop=[('了解家庭','家庭背景与真实处境'),('商量目标','一起明确期望'),('安排小行动','可执行、可调整'),('反馈观察','记录变化与感受'),('调整','更新目标与计划')]
for i,(title,desc) in enumerate(loop):
 x=112+i*299
 box(x,1081,260,124,'white','white',r=16)
 txt(x+130,1120,title,31,True,ha='center')
 txt(x+130,1166,desc,22,False,'muted',ha='center')
 if i<4: arrow(x+270,1143,x+289,1143)
# Loop return path: from adjust back to understand.
line(1438,1205,1438,1245,'green',1.8)
line(1438,1245,242,1245,'green',1.8)
arrow(242,1245,242,1207)
label_bg = box(673,1224,334,42,'sage','sage',r=0)
label_bg.set_zorder(3)
txt(840,1245,'新的观察，回到家庭理解',22,False,'ink',ha='center')

# Platform capabilities below the interaction model, no implementation claim.
section(1350,'03','贯穿全流程的支撑能力')
features=[
 ('多模态','文字、语音、图片','统一理解与表达'),
 ('家庭记忆','标注来源与时间','区分事实与推断','支持查看与纠正'),
 ('主动分析','基于变更触发','有依据才提醒','频率可控'),
 ('可靠执行','行动状态可见','关键步骤确认','失败可重试'),
 ('隐私权限','家庭内访问边界','按角色与用途授权','敏感信息受保护')]
fw=288
for i,item in enumerate(features):
 x=80+i*308
 box(x,1390,fw,242)
 txt(x+24,1435,item[0],31,True)
 line(x+24,1471,x+fw-24,1471)
 for j,s in enumerate(item[1:]): txt(x+24,1512+j*42,s,24,False,'muted')

# Typed domain objects: intentionally not one universal task model.
section(1690,'04','底层对象分类型建模','不把目标、观察和记忆都变成待办任务')
objects=[('家庭','共同边界'),('成员','角色与关系'),('目标','期望的结果'),('计划','行动的路径'),('事项','具体的行动'),('观察','反馈与事实'),('记忆','可复用背景')]
for i,(title,desc) in enumerate(objects):
 x=80+i*220
 box(x,1730,200,122,'pale','pale',r=14)
 txt(x+100,1772,title,31,True,ha='center')
 txt(x+100,1820,desc,23,False,'muted',ha='center')
box(80,1878,1520,125,'white','line',r=16)
txt(108,1917,'对象之间建立关联，而不是强行合并',27,True)
txt(108,1962,'家庭与成员提供背景；目标与计划指引行动；事项、观察与记忆共同支持下一次调整。',25,False,'muted')

# Explicit proposal boundary and next design decision.
line(80,2062,1600,2062)
txt(80,2097,'方案边界与设计原则',23,True,'green')
txt(80,2139,'这是产品方案 v0.1，非已实现功能；详细信息架构、能力边界及对象关系待评审。',25,True)
txt(80,2181,'继承现有设计体系，以理解、确认、克制提醒体现温馨。',24,False,'muted')
txt(80,2222,'本图仅展示产品结构，文档配色不代表 App 主题。',23,False,'muted')
txt(1600,2222,'cat  /  01',18,False,'muted',ha='right')

for ext in ['png','pdf','svg']:
 fig.savefig(OUT/f'cat-product-architecture-v0.1.{ext}',dpi=160,facecolor=C['bg'],metadata={'Title':'cat 产品架构总览 v0.1'} if ext=='pdf' else None)
print('Saved PNG, PDF and outlined SVG to',OUT)
