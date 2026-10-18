# 任务：为 catpaw-m 做一版首发发布材料（PPT deck + 产品介绍视频）

你是独立的一路，和团队其他成员并行各做一版，最后由用户择优。用中文输出。

## 目标
catpaw-m 的首发发布介绍：一份约 15 页的演示 deck（另附附录），加一支约 80 秒的产品介绍视频（或者完整的分镜脚本，配上可直接渲染的素材）。
优先级：**内容逻辑第一，视觉效果第一**。重点讲清楚产品价值、宗旨和理念、四大能力、交互亮点、设计背后的 why、安全与账号，讲 why 而不是 how。

## 怎么拿资料
仓库：https://github.com/Yankj/catpaw-m （私有）。只读，clone 到 `~/Desktop/ai-work/_catpaw-scratch/codex-launch/repo`：

```
cd ~/Desktop/ai-work/_catpaw-scratch/codex-launch
git clone https://github.com/Yankj/catpaw-m.git repo
cd repo
git fetch origin docs/launch-brief chore/v11-integration
git checkout docs/launch-brief        # brief 和素材
# 看最新代码：git show / git ls-tree origin/chore/v11-integration，或另建 git worktree 到 codex-launch/ 下
```

## 必读（唯一事实来源，都在分支 `docs/launch-brief`）
- `docs/launch/BRIEF-v2.md`：定位、理念、四大支柱（主动 / 有记忆 / 能执行 / 可信）、交互亮点、设计 why、安全、技术亮点、对标、叙事线、「不要说」清单。每条都标了 ✅ 已上线 / ◐ 部分完成 / 🔜 v1.2。
- `docs/launch/ASSETS.md`：现有素材索引，每条都写了路径和所在分支。
- `docs/launch/assets/user/`：用户给的品牌板（logo、主张、色板 #FF702A #C64A0B #FFFCF8 #292622 #929298、字体）、开屏图和小猫吉祥物设定图（6 个状态）。
- `docs/launch/assets/` 下其余目录：deck v3（单文件 HTML、30 页渲染图、讲解稿）、真实界面截图、启动页设计、起始图标、animatic v2 和字幕。旧材料只作参考，以 BRIEF-v2 为准。

## 最新代码（信息不够就自己去看，只读）
- 最新集成分支是 `chore/v11-integration`，包含语音、实时文字、账户菜单、开屏登录和吉祥物动画等。
- `main` 是已发布的基线。
- 小猫 `.mov` 动画还没进集成分支，临时位置见 ASSETS.md「小猫」一节。
- 本机路径：不要在 `~/Desktop/ai-work/_wt/` 下的任何 worktree 里改动或构建，也不要碰 `~/Desktop/ai-work/catpaw-m`。只用你自己 clone 的那一份。

## 硬性规则
- 不要 push，不要建远程分支或 PR，不改 GitHub 上的仓库，也不碰 Supabase 和生产环境。
- 不要打印或写出任何密钥，不读 `Local.xcconfig`。
- 不用 BE5C 和 catpaw-video 这两个模拟器。需要界面截图就优先用 ASSETS.md 里已有的。
- ◐ 和 🔜 的功能不能当成已上线来展示：消息信号、服务器推送、完整语音对话、智能选模型、图片生成。
- 视频开头不要出现竖屏录屏塞进横屏、导致一侧空白的构图。

## 交付
全部输出放到 `~/Desktop/ai-work/_catpaw-scratch/codex-launch/out/`（不提交到仓库）：
- `deck/`：可打开的 deck（.pptx 或 HTML）。
- `video/`：成片或分镜脚本，加上素材。
- `NOTES.md`：每一页和每个镜头分别对应 brief 的哪一节，以及你自己补充采集了哪些信息、出处在哪。
