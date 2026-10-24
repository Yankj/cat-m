# 远端分支归档（2026-10-24 邮箱统一改写）

记录时间：2026-10-24 11:17 Asia/Shanghai

本次将全部提交作者/提交者统一为 `Yankj <hello@heydusk.com>`，并强推所有分支与标签。

- 改写前 main：`02a054d5867dd29e41f0bd975a7227ce26563896`
- 改写后 main：`81f00e3fc1bbb74ae72559f36d27e284f90d13cc`

## 已删除（`git cherry` 无独有补丁，相对 main 无未合入工作）

| 分支 | 改写前 SHA | 改写后 SHA（删除前） |
|---|---|---|
| `docs/wave2-event-contracts` | `131c4f532f265b8982e060480e26cc8a82973cbd` | `30ecdbe0c8a276d51bf6125095db13cb884915bd` |
| `feat/agent-memory-recall` | `26fe1a4feafe33630e1bedb7db4de4ce2ee44300` | `d7fdf66f929ae652b8d87c88af7919bc4c8e9b1f` |
| `feat/feature-enroll` | `e51ab0c355d65d1691929b7fe195ee4129dd29d3` | `5d15c896c03c823684e9790d6a36ad3f85d9ce0a` |
| `feat/gemini-interactions` | `71fa1c6afbc53aec1f5a3d546ba7a4074f6d3cdc` | `2f36e298e79409275f66d0998a62f51a3fa0ad5e` |
| `feat/ios-dictation` | `5d398e0b3255b0d4e1ee5017fe072e34d61a5dd3` | `5272c65f6046c9f767d9c7a649ea684094b18783` |
| `feat/ios-dictation-fix` | `cbec8dc39861bd01ecbc0908a7c0901eae4c1577` | `62a903c9f8d6690a1ba38fc8589a8058e1003be8` |
| `feat/ios-markdown-render` | `4dc18acdb3cfab8f46a656422e8b59bdd3421394` | `b9bb4d0c5257a8858c7b4ff2e6438d241544cc63` |
| `feat/ios-onboarding-v2` | `218588d9a247da86c8b026b00dda3fc731ea9d00` | `38ff422927205a1c148ca4ac8ee2dba279ecac7f` |
| `feat/ios-onboarding-v2b` | `d5980ba107232d1b51d10c2400273f39a34515b4` | `d8c168411f0d12b0b22f2c4b7a9935649d1b91ca` |
| `feat/ios-pending-queue` | `aa139391aac4764b77be3dc403d0cb90577608ec` | `3ae5c0f2b87fd72f82a0c3037e34f33685a85b31` |
| `feat/ios-proactive-debug-panel` | `05dfae12e3fdfb2e84711bbf4071736628dfdcad` | `7343149ca5a9399492d80e7a368c5773ae5229cd` |
| `feat/ios-r9-polish` | `320d11614513c1aab44e61a59498141a8ca432a5` | `170d7d8fb928483629f78f70162b829bac596558` |
| `feat/proactive-b2-tasks` | `8d83eb86c6691b0e2d46836f112dc7920040c3e0` | `b9b267dcb46770a9f9ac3c087e29026b1fe989ff` |
| `feat/proactive-b4-push` | `0279f53677af714bfa254e51eb4e3fc6e8276a2a` | `4f9f088f89e5546b88af958d31089f5fd656cd95` |
| `feat/proactive-decision` | `76a40f83361d76c6c06b8ac71fa8526ae343c2f0` | `76ffeb98bd08def1e4767d58c341af5b74987615` |
| `feat/proactive-s1s2` | `f43a17ba51de3e9c0bc9b8ac6ca488793a85f17d` | `0b4ccaeb5c401baa30c67c1808b67ee27893f22a` |

## 保留（仍有相对 main 的独有补丁，或为进行中 PR / preserve 备份）

| 分支 | cherry+ | 改写前 SHA | 改写后 SHA |
|---|---:|---|---|
| `chore/preserve/chat-send-snappy` | 2 | `41f2c572fd95b1d682aeff616d41cd31a42739b5` | `f44a939052271112aab3f0c12ea73c3500ef292e` |
| `chore/preserve/chat-ux-p0-eval` | 2 | `8fde853d908176e9b07c4a8a2af7abdca616b265` | `236f7538cbced97f055d89737f1b8d63a2052cf0` |
| `chore/preserve/first-run-integration-5c84a911` | 65 | `2a674c5323421d761e6a30078b4630f3eafb944f` | `811061e0356f10af98d0cbcfa63a98fae202be0a` |
| `chore/preserve/ios-coredata-stability` | 2 | `826023374cec9862a19140a2a4d313fc0b240106` | `5f90acdd352ff8cadf524076bd41af8246fc73ef` |
| `chore/preserve/peripheral-polish` | 8 | `318fc0d95e667d67a0338f2edb3aaefcd1835b06` | `e9d514971390b1c398c4fbb5bf748a511dc749f2` |
| `chore/preserve/release-v1-0` | 3 | `825ea54aa683eb69c19e4506471e06aa010c4969` | `550c78c638e4d41de2c88bec4084b8ebeefd532f` |
| `chore/preserve/repo-hygiene` | 2 | `d55d58ab0f64170110ceeae79004912067fd3d05` | `78e0fae19b2fc34f5afbdd6841688fdc63e4610b` |
| `chore/preserve/settings-ia` | 2 | `65e447743f61bbe19edc31ba716853d0ec6bd144` | `f0bffed672fbf330facb6df62bfbc8a1e95f3eea` |
| `chore/preserve/stab-353-wip` | 3 | `637cb97dd23d02ef76b3dbf23627f23d69123fbb` | `9518ea7edb3b2027280e0fdb2a954d41f306f725` |
| `chore/preserve/stab-base-wip` | 1 | `350fffdb1af2349d0e2c54f2acd8c2854ffb4199` | `83f51317fc55b19610da863355a35f9c41c2b072` |
| `chore/preserve/stash-temp-image-driver-1903-wip` | 65 | `a1eb718de7fb63069d774cbefe9c1c2d8fafcfb4` | `2e6383743007721c75afaa291e5ead1c6fb73767` |
| `chore/preserve/stash-temp-ui-driver-1830-wip` | 63 | `cdba2da469e815555946187ce946f7e18f16659d` | `0999bfe7e91f3ce0ba62715617ba4cf31f66e1b4` |
| `chore/preserve/stash-temp-ui-driver-wip` | 49 | `34cc26f45bcbb1764e4dedd1d4eb3a602a6ae922` | `2216ffbf7167b53574fe7a1b7ef8d2685315e237` |
| `chore/preserve/v1-conversation-too-long` | 43 | `e6f0cca816a432319ef5b343f145e76ca72a25f6` | `e4409416b67e8eb7f2f912bdcd2ee7c3d1604633` |
| `chore/preserve/v1-image-rate-limit-f08cdf9d` | 77 | `ce30262e8f35723c0e3d0286e75ec6f6b7bfa66f` | `0aa2f2a982ff780b2c2d93ee256abe43e1655890` |
| `chore/preserve/v11-gmail-connector` | 1 | `01cafe666c451c6766307d84c26ea01c3396feae` | `ec224767bfec3ab4dca43eb0e4acab04325ab88b` |
| `chore/v11-integration` | 115 | `aec746f7f1442e6073b4c830af5db5ab2950a919` | `a443a77431165d63158cda5d235e39468a0dba1d` |
| `chore/w4-model-routes` | 9 | `9003112de6f1c6d03615edaeac645948d8291379` | `f65615869c2fcaf25199a29c0f8b36a76b3f3c10` |
| `chore/w5-opencode-zen` | 9 | `9a1843e493a48600a646bc61188a10fbde69d4c9` | `8d983a88c37009d80dc947fc7e2e9f694ae99ad2` |
| `chore/w6-gemini-default` | 10 | `4ab3f15dc871411e5edf0e0efc830ca5c700d390` | `6b6b563f3c557e80b0c013ef837cf00e7294dd3c` |
| `diagnosis/2026-10-15-ios-wip` | 1 | `45d2b4eacfd32b629673aae226dbafdfb210b36a` | `085cd556a2ec14cadd188a736522d7f1762cb5e7` |
| `docs/edge-deploy-log` | 5 | `5a4cc3217b9b5db4500b2c5988f8578e6f41ffe7` | `cf3d8317693801eba88114f4c90b4e160ffadf5d` |
| `docs/family-roadmap` | 1 | `8b56f46e46d5e2770cf46b8194be9327e4322fb4` | `614e08197fccadb67123a834b7e39e7049edeeb3` |
| `docs/launch-brief` | 1 | `12655bfc000d9bc2ce476004bd9088e83144fc7b` | `817b34e1d9071e6e269a52ec9a81236151bc28ab` |
| `feat/chat-send-snappy` | 12 | `c5cb65415e96dbc216328724859f30a499f7e1e5` | `c8745ca48d69b81d6415be96039729d731b16397` |
| `feat/device-call-protocol` | 1 | `c9524cbd19091b932dafc2b943bf024582c63ab0` | `3c562187fa22355c4e6f0dc9c8374dd671ad681c` |
| `feat/family-ios` | 4 | `e2703e5c28f9c27ca9dd729b2d632acda12c5d48` | `03bb4858784a3388a7c32f4e4c2a9a104ba57c16` |
| `feat/grok-cat-companion` | 3 | `1d35d87bce63e31f687fe71a6782f87db61308d1` | `9e69c2e396cdf63b2fa55717f578fb19c5b86da7` |
| `feat/ios-agentic-ui` | 1 | `91e3a020f37f4cca522e2379a6ce1de3392547c8` | `e5a1637fd48b6d5090c4d8292f652d85ebb43a0d` |
| `feat/ios-agentic-ui-v2` | 2 | `2a82eadbf25e194f1a0e6bf809d26b4041d9a78e` | `1c7ddc122368119aecdb7f98587dd51bad3d3673` |
| `feat/ios-agentic-ui-wire` | 3 | `cb20f9bdca5817873122f82efc8c5e04e78e058c` | `593ad549d4b462636afd0b46a13cc9988cd75067` |
| `feat/ios-agentic-ui-wire-v2` | 4 | `b94f06ae4126b2901d0a662239ad572a88886aec` | `541b7fc2e1758587738e4df3a45004f59274c754` |
| `feat/ios-approval-card` | 1 | `0d0c17c23480523a171fa04b2ce5167246b9c330` | `1ab3f09b96e53658a74279fd74a2efcd4820cc1a` |
| `feat/ios-attach-popover` | 2 | `1e700d2402ff0147bce2be5b049899b8aecee6d8` | `fb01cfa760c0ab8c669de4edeae3eb716984729f` |
| `feat/ios-hold-to-talk` | 1 | `3f10ce2ba191f1e6f3291ffd72d4ce28e270e613` | `94074468fcf0b173924b5a43b114dea52e8d73e3` |
| `feat/ios-l2-recovery` | 1 | `755d2be93f63b1c0fc5fecb6d6207d4818a61734` | `2b7ec61ade82720e61fdbe55df5a90d035fbc0b8` |
| `feat/ios-l2-secure-store` | 1 | `efe98d44b9688a8efc1f156acbd945f521ec1118` | `716521fc261aebca5dbea3cb932defd6edea07c7` |
| `feat/ios-last-reply-actions-pager` | 2 | `3965d8ff69dbd00548c0dbf72ccf42453349cc85` | `59c7af3aeb9424bc721284f153aca56ac2766cbc` |
| `feat/ios-live-activity` | 11 | `6e6ca0896856647315eb58a308b2d1627713f55f` | `73b62724c2a7143a0ba3fc4bfa42c33abc13ec25` |
| `feat/ios-memory-chips-m6` | 2 | `a8f424d7e88409d8c5b7e4bfa51badb8fddbbe1d` | `2ef34079f521a31a42301786df7c9fc605813e29` |
| `feat/ios-memory-sse-wire` | 2 | `425b5483a96a5b8d3885ccdeca1f003bc70f4346` | `2bc996585b887da02e00932b1ba0879b7c33a24c` |
| `feat/ios-memory-sync-m5` | 1 | `1b210119f9c3c67dc5491c413b213b9288f95efd` | `c08d516cb7d6f278c7a42efd574a1fb5e00656ce` |
| `feat/ios-mvp-integration-v2` | 11 | `8c9e8eb0d81d479be540d96d296798807ae6a703` | `5125b544ad71dca3f6d6a174c80fb233d7c547d0` |
| `feat/ios-mvp-routing-resilience` | 6 | `880c2898030ff52b746f67e4d058288398d2e2b6` | `09a82269cc9c360c95126e1c9b0edad9b14b5f82` |
| `feat/ios-mvp-ui` | 3 | `41cd927ee599b90132ddfb2379d2d732251de387` | `6d0bfe3299c1aefb9066efbfeb3a8e2dfa70e30d` |
| `feat/ios-permission-degrade` | 1 | `360769ad7410edbb5c1534118678695ef008dcb5` | `bbe4e4dfd8ab324f98c9841d57d1d19741e79604` |
| `feat/ios-proactive-cards` | 1 | `c42a71c9741133c161f5c48a4ab8e9e309324f01` | `31b6bda5d9773b872b023ed7da3add65a37f57b6` |
| `feat/ios-proactive-cards-v2` | 1 | `0a4b040dda00c45aa9f8ca389801415c34143fe7` | `2eb8e0ae32ae86a28977c719d45db85ba571fc0e` |
| `feat/ios-sidebar-redesign` | 1 | `61d9df5b3815107ecea60eda71a582befd6cc818` | `961a4e561338a0ade86647953887f5d4b27c455f` |
| `feat/ios-task-card` | 1 | `38b7684e3b4e2ffd374e91c9a2c57f7440a1a18f` | `b7a61c418026283d92495d87370d2fa2bbd89b32` |
| `feat/ios-v2-task-confirm` | 1 | `08901c717d9bf6205d0eee5b983edada1c95e5f9` | `9b634e3510bd8b59e849f30ea47b93e5de0534b8` |
| `feat/ios-v4-inapp-banner` | 1 | `e6d83944cb2ab30198cd85f0055befcd61a066d0` | `376825df509186e6a0f281078b9bd442a6746fb5` |
| `feat/ios-v5-widgets` | 1 | `18ef67929361836ac12301473cfd8edb7577e38f` | `58d7d34746ded829c3d7c6f5e3da7a1f8bf35d01` |
| `feat/ios-w2-device-confirm` | 2 | `126ba4277e1b2c0cb86338b29b75fef900bbeabf` | `8b0486a04d981ab5ea5907ed4ce81070501ac50c` |
| `feat/ios-w2-image-viewer` | 2 | `f004026c6060052609df07e0062ba45328d056ab` | `e8696c953b8c794901db9b3686f1b0a2abfc70bc` |
| `feat/ios-w2-memory-ui` | 1 | `36af7ac2750ba307948dd9725c4d99380007474c` | `7ba50404e5b119eee2f2d43800dca425bd9f9002` |
| `feat/ios-w2-message-longpress` | 1 | `23dcbeaa19f93513b2b2d81d4a2edfff8636aa61` | `fbae91950bf4919483e265084847ffbc63f00a3a` |
| `feat/ios-w2-proactive-suggestion` | 1 | `05997419d929da75cc81f3b36f00a8fa19a9b7f1` | `e8df98ca3a17a4525b631a6ed0c0e10fcaa6d4ee` |
| `feat/ios-w2-proactive-why` | 2 | `a7df73c162adaa186e2e19d30dca4e3fac1185fd` | `74de616c39b801f66287bed3a155ea3616c64f17` |
| `feat/ios-w2-receipt-permission` | 1 | `d0fcde4c6897405fb9fb20ae1c236b61abfffd24` | `62c603b57a9a357ad166ac6acf4355e06fbe36ad` |
| `feat/ios-xcuitest-acceptance` | 10 | `051c27a72b6916189b99bc4df5ef0b41caefd51e` | `e139e2edbd5f9ee566c66b3562779ab6fa512cd3` |
| `feat/opencode-route-status` | 3 | `5e919dd3e38e85845d4d67c84c731818492f724c` | `0d57bcbb1fb3db169a0fb98017c85843c4c10b93` |
| `feat/parenting-core` | 20 | `4cdb61f591586ea9680d8beeb6ee172a7b8e929b` | `bde311b75efe5dd75765e392fef4d8f779e07e27` |
| `feat/proactive-goal-kernel` | 4 | `1919ce8159d64476c4834b52f0a86585e25800f9` | `388bad477885f3cc59a664701f69334a1e4a4d01` |
| `feat/proactive-tasks-backend` | 1 | `ffa1bf633f9ec35aa43fc78c9d66133631a11f06` | `6addcd85d45434858e950797b50da2be2aa0c979` |
| `feat/r11-brand-motion` | 2 | `0a99406be93637d9dd7af7f28d05f2ef65d05f1d` | `a8dfa5a2ce147aaa04e95c83b4aa33c75239329a` |
| `feat/s05-bounded-work` | 3 | `04a137071525070637c77dc8f0b8103b7866ceae` | `a1a9f2f623c66a0c5996bf398c18c2453bbee378` |
| `fix/agent-memory-vector-grant` | 39 | `11a2c609e382f78b5faa2d605628e794f59f7daf` | `a14b4842d6857a1645a762d1510a5ffae3d82ccd` |
| `fix/calendar-device-prompt` | 3 | `f1ce8722c241ea702a188c6f8b7c7d5a4ac73086` | `39bfcfeb10e44acc640eae9d83f969c591577cc1` |
| `fix/codex-p0` | 3 | `336ce74d770be8f2bf1f0337b5e48af82f2f6086` | `4272156164b4b0b0b7359d27a220839c41a4daa2` |
| `fix/edge-tests-81` | 1 | `cd4395cce09853dd7cb73984c37796ae49fbfd54` | `b51435a647579f1094520b5846deb1237edcc852` |
| `fix/ios-markdown-semantic-fonts` | 1 | `82e3b4c87397fd2e659d97cfee0d6848b8a2812c` | `610f83fe3a22a4992b5a6ccc5ca79d12ecb547e6` |
| `fix/model-route-review` | 1 | `f83ef7a179d53edb6878aa1f5ed105ea116c315d` | `8549cecd3e47e3bbc7c52893bab95d49e4412d90` |
| `fix/nobug-p0` | 3 | `73e3fff55c95a342baf25e17121a68da30bc9143` | `c50ad8e7be75815ddb53dc336f63d275727d4aea` |
| `fix/p0-2-4-memory-feedback` | 5 | `8a87142fde55ce5a5c116a6d3133c37439fbdf28` | `2656e0532722a0931c8cdfa0cd3a0129411a44b4` |
| `fix/p0-3-5-proactive` | 7 | `08836caf3f21de2cb4eb9b80f57aa2f2e474e861` | `7ea6bea5646384855fbd898c3f46b3126e1c985e` |
| `refactor/mimi-roadmap` | 13 | `c406817447262b755ae9ee9236d7487d22e51a87` | `7ec021b71ad415b68ee51f2205eff5ba68f235d3` |
| `test/family-cloud-verification` | 2 | `543b62b569a970d717796dcd3a98d9c11274040b` | `bf466ec33d251fbb905e5233efbd98156d733edd` |

## 说明

- `chore/preserve/*` 为有意保留的备份分支，未删。
- `#123`（`feat/parenting-core`）与 `#124`（`refactor/mimi-roadmap`）仍为 draft，未合并。
- 历史改写后旧 SHA 失效；恢复请用上表「改写后 SHA」或本仓库 bundle/备份。
- 提交邮箱统一为公司邮箱 `hello@heydusk.com`；请在 GitHub 开启邮箱隐私，并阻止推送暴露个人邮箱的提交。
