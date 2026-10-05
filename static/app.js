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

function renderNpm(npm, hosts) {
  const proxyHosts = collection(npm.proxy_hosts);
  const redirectionHosts = collection(npm.redirection_hosts);
  const streams = collection(npm.streams);
  if (!proxyHosts.length && !redirectionHosts.length && !streams.length) return '';

  const lxcFor = (address) => hosts.find((host) => (host.ips || []).includes(address));
  const target = (item) => {
    const scheme = item.forward_scheme || 'http';
    const address = item.forward_host || '?';
    const port = item.forward_port ? `:${item.forward_port}` : '';
    const lxc = lxcFor(address);
    return `${scheme}://${address}${port}${lxc ? ` · ${lxc.hostname || `LXC ${lxc.ctid}`}` : ''}`;
  };
  const proxyRows = proxyHosts.map((item) => `
    <div class="npm-row" data-npm-text="${escapeHtml(`${(item.domain_names || []).join(' ')} ${item.forward_host || ''} ${item.forward_port || ''}`)}">
      <strong>${escapeHtml((item.domain_names || []).join(', ') || 'sin dominio')}</strong>
      <span class="ports">${escapeHtml(target(item))}</span>
    </div>`).join('');
  const redirectRows = redirectionHosts.map((item) => `
    <div class="npm-row" data-npm-text="${escapeHtml(`${(item.domain_names || []).join(' ')} ${item.forward_domain_name || ''}`)}">
      <strong>${escapeHtml((item.domain_names || []).join(', ') || 'sin dominio')}</strong>
      <span class="ports">→ ${escapeHtml(item.forward_domain_name || '?')} · HTTP ${escapeHtml(item.forward_http_code || '?')}</span>
    </div>`).join('');
  const streamRows = streams.map((item) => `
    <div class="npm-row" data-npm-text="${escapeHtml(`${item.incoming_port || ''} ${item.forwarding_host || ''} ${item.forwarding_port || ''}`)}">
      <strong>Entrada :${escapeHtml(item.incoming_port || '?')}</strong>
      <span class="ports">→ ${escapeHtml(item.forwarding_host || '?')}:${escapeHtml(item.forwarding_port || '?')}</span>
    </div>`).join('');
  const group = (title, rows, count) => rows ? `<div class="npm-group"><h3>${title} <span class="muted">${count}</span></h3>${rows}</div>` : '';
  return `<section class="npm-section">
    <div class="detail-heading"><div><h2>Rutas Nginx Proxy Manager</h2><p class="muted">${escapeHtml(npm.url || 'API NPM')}</p></div>
    <label class="port-search">Buscar ruta<input id="npm-search-input" type="search" placeholder="Dominio o IP"></label></div>
    ${group('Proxy hosts', proxyRows, proxyHosts.length)}
    ${group('Redirecciones', redirectRows, redirectionHosts.length)}
    ${group('Streams TCP/UDP', streamRows, streams.length)}
  </section>`;
}

async function showDetail(id) {
  try {
    const result = await request(`/api/snapshots/${id}`);
    state.selected = id;
    const hosts = result.data.containers || [];
    const npm = result.data.npm || {};
    const npmMarkup = renderNpm(npm, hosts);
    $('detail').hidden = false;
    $('comparison').hidden = true;
    $('detail').innerHTML = `<div class="detail-heading"><div><h2>${escapeHtml(result.metadata.filename)}</h2><p class="muted">Generado: ${date(result.metadata.generated)} · Subido: ${date(result.metadata.uploaded_at)}</p></div><label class="port-search">Buscar puerto<input id="port-search-input" type="search" placeholder="Ej. 8080"></label></div>` +
      hosts.map((host, index) => `<details class="host" open data-host-index="${index}"><summary class="host-title"><span>${escapeHtml(host.hostname || `ctid-${host.ctid}`)} <span class="muted">${host.docker ? 'Docker' : 'LXC'} · ${(host.ips || []).join(', ')}</span></span><button class="random-port" type="button" data-host-index="${index}">Puerto libre</button></summary>` +
        (host.containers || []).map((c) => `<div class="container-row" data-ports="${escapeHtml((c.ports || []).join(' '))}"><strong>${escapeHtml(c.name)}</strong><span class="ports">${(c.ports || []).map(escapeHtml).join('<br>') || 'sin puertos publicados'}</span></div>`).join('') + '</details>').join('') + npmMarkup;
    $('port-search-input').addEventListener('input', filterPorts);
    const npmSearch = $('npm-search-input');
    if (npmSearch) npmSearch.addEventListener('input', filterNpm);
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

function filterNpm(event) {
  const query = event.target.value.trim().toLowerCase();
  document.querySelectorAll('.npm-row').forEach((row) => {
    row.hidden = query && !row.dataset.npmText.toLowerCase().includes(query);
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
