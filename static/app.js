const state = { snapshots: [], selected: null };
const $ = (id) => document.getElementById(id);
const date = (value) => value ? new Date(value).toLocaleString('es-ES', { dateStyle: 'medium', timeStyle: 'short' }) : 'sin fecha';
const notice = (message) => { $('notice').textContent = message; $('notice').hidden = !message; };

function setTheme(dark) {
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  localStorage.setItem('portuse-theme', dark ? 'dark' : 'light');
  $('theme-toggle').setAttribute('aria-pressed', String(dark));
  $('theme-toggle').setAttribute('aria-label', dark ? 'Activar modo claro' : 'Activar modo oscuro');
  $('theme-toggle').querySelector('.theme-label').textContent = dark ? 'Modo claro' : 'Modo oscuro';
}

async function request(url, options) {
  const response = await fetch(url, options);
  const body = await response.json();
  if (!response.ok) throw new Error(body.detail || 'No se pudo completar la operación');
  return body;
}

function renderSelectors() {
  const options = state.snapshots.map((s) => `<option value="${s.id}">${s.filename} · ${date(s.uploaded_at)}</option>`).join('');
  $('from-select').innerHTML = options;
  $('to-select').innerHTML = options;
  if (state.snapshots.length > 1) $('from-select').selectedIndex = 1;
  $('to-select').selectedIndex = 0;
  $('compare-button').disabled = state.snapshots.length < 2;
}

function renderCards() {
  $('snapshot-count').textContent = `${state.snapshots.length} ${state.snapshots.length === 1 ? 'archivo' : 'archivos'}`;
  $('snapshot-list').innerHTML = state.snapshots.length ? state.snapshots.map((s, i) => `
    <article class="card ${i === 0 ? 'latest' : ''} ${state.selected === s.id ? 'active' : ''}" data-id="${s.id}">
      <div class="card-head"><div><h3>${escapeHtml(s.filename)}</h3><span class="muted">${date(s.uploaded_at)}</span></div>${i === 0 ? '<span class="tag">MÁS RECIENTE</span>' : ''}</div>
      <div class="stats"><span>${s.host_count} hosts</span><span>${s.container_count} contenedores</span><span>${s.published_port_count} puertos</span></div>
    </article>`).join('') : '<div class="muted">Carga tu primer archivo JSON para comenzar.</div>';
  document.querySelectorAll('.card').forEach((card) => card.addEventListener('click', () => showDetail(card.dataset.id)));
}

function escapeHtml(value) { return String(value).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c])); }

function collection(value) {
  if (Array.isArray(value)) return value;
  return value?.items || value?.data || [];
}

async function showDetail(id) {
  try {
    const result = await request(`/api/snapshots/${id}`);
    state.selected = id;
    const hosts = result.data.containers || [];
    $('detail').hidden = false;
    $('comparison').hidden = true;
    $('detail').innerHTML = `<div class="detail-heading"><div><h2>${escapeHtml(result.metadata.filename)}</h2><p class="muted">Generado: ${date(result.metadata.generated)} · Subido: ${date(result.metadata.uploaded_at)}</p></div><label class="port-search">Buscar puerto<input id="port-search-input" type="search" placeholder="Ej. 8080"></label></div>` +
      hosts.map((host, index) => {
        const routes = host.npm_routes || [];
        const routeMarkup = (route) => `<div class="npm-route" data-ports="${escapeHtml(`${(route.domain_names || []).join(' ')} ${route.forward_host || ''} ${route.forward_port || ''}`)}"><span>Ruta NPM: ${escapeHtml((route.domain_names || []).join(', ') || 'sin dominio')}</span><span class="ports">${escapeHtml(`${route.forward_scheme || 'http'}://${route.forward_host || '?'}:${route.forward_port || '?'}`)}</span></div>`;
        const rows = (host.containers || []).map((container) => {
          const containerRoutes = routes.filter((route) => route.container === container.name);
          return `<div class="container-row" data-ports="${escapeHtml((container.ports || []).join(' '))}"><strong>${escapeHtml(container.name)}</strong><div class="ports">${(container.ports || []).map(escapeHtml).join('<br>') || 'sin puertos publicados'}${containerRoutes.map(routeMarkup).join('')}</div></div>`;
        }).join('');
        const unmatchedRoutes = routes.filter((route) => !route.container || !(host.containers || []).some((container) => container.name === route.container));
        return `<details class="host" open data-host-index="${index}"><summary class="host-title"><span>${escapeHtml(host.hostname || `ctid-${host.ctid}`)} <span class="muted">${host.docker ? 'Docker' : 'LXC'} · ${(host.ips || []).join(', ')}</span></span><button class="random-port" type="button" data-host-index="${index}">Puerto libre</button></summary>${rows}${unmatchedRoutes.map(routeMarkup).join('')}</details>`;
      }).join('');
    $('port-search-input').addEventListener('input', filterPorts);
    document.querySelectorAll('.random-port').forEach((button) => button.addEventListener('click', getRandomPort));
    renderCards();
  } catch (error) { notice(error.message); }
}

function filterPorts(event) {
  const query = event.target.value.trim().toLowerCase();
  document.querySelectorAll('.host').forEach((host) => {
    let visible = 0;
    host.querySelectorAll('.container-row').forEach((row) => {
      const matches = !query || row.dataset.ports.toLowerCase().includes(query);
      row.hidden = !matches;
      if (matches) visible += 1;
    });
    host.hidden = visible === 0;
  });
}

async function getRandomPort(event) {
  event.preventDefault();
  event.stopPropagation();
  const button = event.currentTarget;
  try {
    const result = await request(`/api/snapshots/${state.selected}/random-port?host_index=${button.dataset.hostIndex}`);
    showPortModal(result.port);
  } catch (error) { notice(error.message); }
}

function showPortModal(port) {
  $('port-value').textContent = port;
  $('copy-status').textContent = '';
  $('copy-port').textContent = 'Copiar puerto';
  $('port-modal').hidden = false;
  $('copy-port').focus();
}

function closePortModal() {
  $('port-modal').hidden = true;
}

async function copyPort() {
  try {
    await navigator.clipboard.writeText($('port-value').textContent);
    $('copy-port').textContent = 'Copiado';
    $('copy-status').textContent = 'El puerto está en el portapapeles.';
  } catch (error) {
    $('copy-status').textContent = 'No se pudo copiar automáticamente. Selecciona el puerto manualmente.';
  }
}

async function compare() {
  try {
    const result = await request(`/api/compare?from_id=${$('from-select').value}&to_id=${$('to-select').value}`);
    const group = (title, values, cls, formatter) => `<div class="change-group"><h3>${title} <span class="muted">${values.length}</span></h3>${values.map((item) => `<div class="change ${cls}">${formatter(item)}</div>`).join('') || '<p class="muted">Sin cambios</p>'}</div>`;
    $('comparison').hidden = false; $('detail').hidden = true;
    $('comparison').innerHTML = `<h2>Comparación</h2><p class="muted">${escapeHtml(result.from.filename)} → ${escapeHtml(result.to.filename)}</p>` +
      group('Añadidos', result.added, 'added', (x) => `${escapeHtml(x.key)}<br>${(x.ports || []).map(escapeHtml).join(' · ') || 'sin puertos'}`) +
      group('Eliminados', result.removed, 'removed', (x) => `${escapeHtml(x.key)}<br>${(x.ports || []).map(escapeHtml).join(' · ') || 'sin puertos'}`) +
      group('Puertos modificados', result.changed, 'changed', (x) => `${escapeHtml(x.key)}<br>Antes: ${x.before.map(escapeHtml).join(' · ') || '—'}<br>Ahora: ${x.after.map(escapeHtml).join(' · ') || '—'}`);
  } catch (error) { notice(error.message); }
}

async function load() {
  try { state.snapshots = await request('/api/snapshots'); renderSelectors(); renderCards(); if (state.snapshots[0]) showDetail(state.snapshots[0].id); }
  catch (error) { notice(error.message); }
}
$('theme-toggle').addEventListener('click', () => setTheme(document.documentElement.dataset.theme !== 'dark'));
setTheme(localStorage.getItem('portuse-theme') === 'dark');
$('close-port-modal').addEventListener('click', closePortModal);
$('copy-port').addEventListener('click', copyPort);
$('port-modal').addEventListener('click', (event) => { if (event.target.hasAttribute('data-close-modal')) closePortModal(); });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !$('port-modal').hidden) closePortModal(); });
$('file-input').addEventListener('change', async (event) => {
  const file = event.target.files[0]; if (!file) return;
  try { await request('/api/snapshots', { method: 'POST', body: (() => { const data = new FormData(); data.append('file', file); return data; })() }); notice(''); await load(); }
  catch (error) { notice(error.message); }
  event.target.value = '';
});
$('compare-button').addEventListener('click', compare);
load();
