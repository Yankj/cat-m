const $ = (selector) => document.querySelector(selector);
const all = (selector) => [...document.querySelectorAll(selector)];
const themeButton = $('#theme-toggle');
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeButton.textContent = theme === 'dark' ? '浅色' : '深色';
  themeButton.setAttribute('aria-label', theme === 'dark' ? '切换为浅色模式' : '切换为深色模式');
}
let savedTheme;
try { savedTheme = localStorage.getItem('catpaw-theme'); } catch {}
const systemTheme = matchMedia('(prefers-color-scheme: dark)');
setTheme(savedTheme || (systemTheme.matches ? 'dark' : 'light'));
themeButton.addEventListener('click', () => {
  savedTheme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  setTheme(savedTheme);
  try { localStorage.setItem('catpaw-theme', savedTheme); } catch {}
});
systemTheme.addEventListener('change', (event) => { if (!savedTheme) setTheme(event.matches ? 'dark' : 'light'); });
const menuButton = $('#menu-toggle');
const nav = $('#main-nav');
function closeMenu() { nav.classList.remove('open'); menuButton.setAttribute('aria-expanded', 'false'); menuButton.textContent = '菜单'; }
menuButton.addEventListener('click', () => { const open = nav.classList.toggle('open'); menuButton.setAttribute('aria-expanded', String(open)); menuButton.textContent = open ? '关闭' : '菜单'; });
nav.addEventListener('click', (e) => { if (e.target.closest('a')) closeMenu(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && nav.classList.contains('open')) { closeMenu(); menuButton.focus(); } });
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
if (!reducedMotion.matches && 'IntersectionObserver' in window) {
  document.documentElement.classList.add('js-motion');
  const observer = new IntersectionObserver((entries) => entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('visible'); observer.unobserve(e.target); } }), {threshold:0.08});
  all('.reveal').forEach((node) => observer.observe(node));
  reducedMotion.addEventListener('change', (e) => { if (e.matches) document.documentElement.classList.remove('js-motion'); });
}
all('[data-minutes]').forEach((button) => button.addEventListener('click', () => {
  const mins = Number(button.dataset.minutes);
  const reminder = 10 * 60 + 23 - mins;
  const formatted = `${String(Math.floor(reminder / 60)).padStart(2, '0')}:${String(reminder % 60).padStart(2, '0')}`;
  $('#suggested-time').textContent = formatted;
  all('[data-reminder-time]').forEach((n) => n.textContent = formatted);
  all('[data-lead-minutes]').forEach((n) => n.textContent = String(mins));
  all('[data-minutes]').forEach((n) => n.setAttribute('aria-pressed', String(n === button)));
}));
all('[data-cat]').forEach((button) => button.addEventListener('click', () => {
  $('#mascot-large').src = `assets/cat-${button.dataset.cat}.webp`;
  $('#mascot-large').alt = button.dataset.caption;
  $('#mascot-caption').textContent = button.dataset.caption;
  all('[data-cat]').forEach((n) => n.setAttribute('aria-pressed', String(n === button)));
}));
const video = $('#launch-film');
if (video) {
  const cover = $('#film-play');
  const error = $('#film-error');
  const play = async () => {
    cover.hidden = true;
    error.hidden = true;
    try { await video.play(); } catch { error.textContent = '未能自动播放，请使用播放器控制条，或下载原片观看。'; error.hidden = false; }
  };
  cover.addEventListener('click', play);
  all('[data-play-link]').forEach((link) => link.addEventListener('click', () => { play(); }));
  video.addEventListener('error', () => { cover.hidden = true; error.textContent = '视频暂时无法加载。你可以通过下方「下载原片」链接打开文件。'; error.hidden = false; });
}
