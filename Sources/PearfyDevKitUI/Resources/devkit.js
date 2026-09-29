(() => {
  const root = '/__pearfy/devkit/api';
  const tokenStorageKey = 'pearfy.devkit.bearer-token';
  const $ = (id) => document.getElementById(id);
  const auth = $('auth');
  const dashboard = $('dashboard');
  const message = $('message');
  const fmt = (value, suffix = '') => value == null ? 'N/D' : `${Number(value).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}${suffix}`;
  let token = '';
  let routes = [];
  let hasWindowMetrics = false;
  let showEmptyRoutes = false;
  let traceNodes = new Map();
  let refreshInProgress = false;

  function loadToken() {
    try { return localStorage.getItem(tokenStorageKey) || ''; } catch { return ''; }
  }

  function persistToken(value) {
    try {
      localStorage.setItem(tokenStorageKey, value);
      return true;
    } catch {
      return false;
    }
  }

  function removeStoredToken(expectedValue) {
    try {
      if (expectedValue === undefined || localStorage.getItem(tokenStorageKey) === expectedValue) {
        localStorage.removeItem(tokenStorageKey);
      }
    } catch {}
  }

  async function request(endpoint) {
    const query = new URLSearchParams({ window: $('period').value });
    if ($('instance').value) query.set('instance', $('instance').value);
    const response = await fetch(`${root}/${endpoint}?${query}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
      cache: 'no-store',
      credentials: 'same-origin',
      referrerPolicy: 'no-referrer'
    });
    if (response.status === 401) {
      const rejectedToken = token;
      removeStoredToken(rejectedToken);
      token = '';
      throw new Error('Token inválido. Confira a configuração da aplicação.');
    }
    if (!response.ok) throw new Error(`Fonte indisponível (${response.status}).`);
    return response.json();
  }

  function cell(row, value, className = '') {
    const element = document.createElement('td');
    element.textContent = value;
    if (className) element.className = className;
    row.append(element);
  }

  function routeRow(route) {
    const row = document.createElement('tr');
    const metrics = route.metrics;
    const latency = (value) => !metrics ? 'N/D' : metrics.requestCount === 0 ? '—' : fmt(value, ' ms');
    cell(row, route.method, `method ${route.method.toLowerCase()}`);
    cell(row, route.pathTemplate, 'path');
    cell(row, route.group || '—');
    cell(row, metrics ? fmt(metrics.requestCount) : 'N/D');
    cell(row, latency(metrics?.averageLatencyMilliseconds));
    cell(row, latency(metrics?.p50Milliseconds));
    cell(row, latency(metrics?.p95Milliseconds));
    cell(row, latency(metrics?.p99Milliseconds));
    cell(row, metrics ? fmt(metrics.errorCount) : 'N/D');
    return row;
  }

  function paintRoutes() {
    const term = $('search').value.trim().toLowerCase();
    const matchesSearch = (route) => `${route.method} ${route.pathTemplate} ${route.group || ''}`.toLowerCase().includes(term);
    const filtered = routes.filter((route) => {
      const hasTraffic = Number(route.metrics?.requestCount || 0) > 0;
      return matchesSearch(route) && (!hasWindowMetrics || showEmptyRoutes || hasTraffic);
    });
    const list = $('routes');
    list.replaceChildren(...filtered.map((route) => routeRow(route)));
    const empty = $('route-empty');
    if (empty) {
      empty.hidden = filtered.length > 0;
      empty.textContent = term
        ? hasWindowMetrics && !showEmptyRoutes && routes.some((route) => matchesSearch(route))
          ? 'A rota existe, mas não recebeu chamadas nesta janela. Ative “Mostrar sem chamadas”.'
          : 'Nenhuma rota corresponde ao filtro.'
        : hasWindowMetrics
          ? 'Nenhuma rota com chamadas nesta janela.'
          : 'Nenhuma rota disponível nesta fonte.';
    }
  }

  function paintCards(overview) {
    const cards = [
      ['Requisições', fmt(overview.requestCount)],
      ['Erros', fmt(overview.errorCount)],
      ['Latência média', fmt(overview.averageLatencyMilliseconds, ' ms')],
      ['P95', fmt(overview.p95Milliseconds, ' ms')],
      ['CPU do processo', fmt(overview.cpuPercent, '%')],
      ['Memória RSS', fmt(overview.memoryBytes == null ? null : overview.memoryBytes / 1024 / 1024, ' MB')]
    ];
    $('cards').replaceChildren(...cards.map(([label, value]) => {
      const article = document.createElement('article');
      article.className = 'metric-card';
      const title = document.createElement('span');
      title.className = 'muted';
      title.textContent = label;
      const number = document.createElement('strong');
      number.textContent = value;
      article.append(title, number);
      return article;
    }));
    $('scope').textContent = `${overview.scope}${overview.windowApplied ? ` · ${overview.requestedWindow}` : ' · janela não disponível nesta fonte'}${overview.latencyPercentilesEstimated ? ' · percentis estimados pelos buckets' : ''}`;
  }

  function paintRecords(id, rows, render, emptyMessage) {
    const target = $(id);
    target.replaceChildren();
    if (!rows.length) {
      target.textContent = emptyMessage;
      target.classList.add('empty');
      return;
    }
    target.classList.remove('empty');
    rows.forEach((item) => target.append(render(item)));
  }

  function record(label, detail) {
    const row = document.createElement('div');
    row.className = 'record';
    const title = document.createElement('b');
    title.textContent = label;
    const text = document.createElement('span');
    text.textContent = detail;
    row.append(title, text);
    return row;
  }

  function statusClass(trace) {
    if (Number(trace.statusCode) >= 500 || trace.status === 'error' || trace.status === 'server-error') return 'server-error';
    if (Number(trace.statusCode) >= 400 || trace.status === 'client-error') return 'client-error';
    return '';
  }

  function timeLabel(value) {
    const date = new Date(value);
    return Number.isNaN(date.valueOf()) ? '—' : date.toLocaleString('pt-BR');
  }

  function isWorkTrace(trace) {
    if (trace.kind === 'work') return true;
    if (trace.kind === 'request') return false;
    return trace.method == null && trace.routeTemplate == null;
  }

  function traceCard(trace) {
    const isWork = isWorkTrace(trace);
    const article = document.createElement('article');
    article.className = 'trace-card';
    const summary = document.createElement('div');
    summary.className = 'trace-summary';

    const method = document.createElement('b');
    method.className = `method ${isWork ? 'work' : (trace.method || 'other').toLowerCase()}`;
    method.textContent = isWork ? 'WORK' : (trace.method || 'HTTP');
    const route = document.createElement('span');
    route.className = 'trace-route';
    const firstSpan = Array.isArray(trace.spans) ? trace.spans[0] : null;
    route.textContent = isWork
      ? (firstSpan?.name || 'Work sem nome')
      : (trace.routeTemplate || 'rota não identificada');
    const time = document.createElement('span');
    time.className = 'trace-meta';
    time.textContent = timeLabel(trace.startedAt);
    const status = document.createElement('span');
    status.className = `trace-status ${statusClass(trace)}`;
    status.textContent = trace.statusCode == null ? (trace.status || 'N/D') : String(trace.statusCode);
    const duration = document.createElement('span');
    duration.className = 'trace-meta';
    duration.textContent = fmt(trace.durationMilliseconds, ' ms');
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'trace-toggle';
    toggle.textContent = 'Detalhes';
    toggle.setAttribute('aria-expanded', 'false');
    summary.append(method, route, time, status, duration, toggle);

    const details = document.createElement('div');
    details.className = 'trace-details';
    details.hidden = true;
    const traceID = document.createElement('code');
    traceID.className = 'trace-id';
    traceID.textContent = `Trace ID · ${trace.traceID}`;
    details.append(traceID);
    const spans = Array.isArray(trace.spans) ? trace.spans : [];
    if (!spans.length) {
      const empty = document.createElement('p');
      empty.className = 'trace-empty';
      empty.textContent = 'Este provider não forneceu spans para o trace.';
      details.append(empty);
    } else {
      const list = document.createElement('div');
      list.className = 'span-list';
      const traceStart = new Date(trace.startedAt).valueOf();
      const traceDuration = Math.max(1, Number(trace.durationMilliseconds) || 1);
      spans.forEach((span) => {
        const row = document.createElement('div');
        row.className = `trace-span${span.status === 'error' ? ' error' : ''}`;
        const name = document.createElement('span');
        name.className = 'span-name';
        name.textContent = span.name || 'span';
        const track = document.createElement('span');
        track.className = 'span-track';
        const bar = document.createElement('span');
        bar.className = 'span-bar';
        const spanStart = new Date(span.startedAt).valueOf();
        const start = Number.isFinite(spanStart) && Number.isFinite(traceStart)
          ? Math.max(0, Math.min(100, ((spanStart - traceStart) / traceDuration) * 100)) : 0;
        const spanDuration = Math.max(0, Number(span.durationMilliseconds) || 0);
        const width = Math.max(spanDuration > 0 ? 1 : 0, Math.min(100 - start, (spanDuration / traceDuration) * 100));
        bar.style.left = `${start}%`;
        bar.style.width = `${width}%`;
        track.append(bar);
        const elapsed = document.createElement('span');
        elapsed.className = 'trace-meta';
        elapsed.textContent = fmt(span.durationMilliseconds, ' ms');
        row.append(name, track, elapsed);
        list.append(row);
      });
      details.append(list);
    }

    toggle.addEventListener('click', () => {
      details.hidden = !details.hidden;
      toggle.setAttribute('aria-expanded', String(!details.hidden));
      toggle.textContent = details.hidden ? 'Detalhes' : 'Fechar';
    });
    article.append(summary, details);
    if (trace.traceID) traceNodes.set(trace.traceID, {
      article,
      toggle,
      sectionID: isWork ? 'work-traces' : 'input-traces'
    });
    return article;
  }

  function paintTraceList(targetID, traces, emptyMessage) {
    const target = $(targetID);
    target.replaceChildren();
    if (!traces.length) {
      target.className = 'empty';
      target.textContent = emptyMessage;
      return;
    }
    target.className = 'trace-list';
    traces.forEach((trace) => target.append(traceCard(trace)));
  }

  function paintTraces(traces) {
    traceNodes = new Map();
    const inputTraces = traces.filter((trace) => !isWorkTrace(trace));
    const workTraces = traces.filter(isWorkTrace);
    paintTraceList('input-traces-content', inputTraces, 'Nenhum trace de rota de entrada nesta janela.');
    paintTraceList('work-traces-content', workTraces, 'Nenhum trace de work nesta janela.');
  }

  function paintErrors(errors) {
    const target = $('errors-content');
    target.replaceChildren();
    if (!errors.length) {
      target.classList.add('empty');
      target.textContent = 'Nenhum erro nesta janela.';
      return;
    }
    target.classList.remove('empty');
    const table = document.createElement('table');
    table.className = 'error-table';
    const head = document.createElement('thead');
    const header = document.createElement('tr');
    ['QUANDO', 'STATUS', 'MÉTODO', 'ROTA', 'DURAÇÃO', 'TRACE'].forEach((label) => {
      const cell = document.createElement('th');
      cell.scope = 'col';
      cell.textContent = label;
      header.append(cell);
    });
    head.append(header);
    const body = document.createElement('tbody');
    errors.forEach((error) => {
      const row = document.createElement('tr');
      cell(row, timeLabel(error.timestamp));
      cell(row, String(error.statusCode), 'error-code');
      cell(row, error.method || 'HTTP');
      cell(row, error.routeTemplate || 'rota não identificada', 'error-route');
      cell(row, fmt(error.durationMilliseconds, ' ms'));
      const traceCell = document.createElement('td');
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'error-trace-link';
      button.textContent = String(error.traceID || '').slice(0, 12);
      button.title = `Abrir trace ${error.traceID || ''}`;
      button.addEventListener('click', () => {
        const trace = traceNodes.get(error.traceID);
        if (!trace) return;
        if (trace.article.querySelector('.trace-details').hidden) trace.toggle.click();
        location.hash = `#${trace.sectionID}`;
        trace.article.scrollIntoView({ behavior: 'smooth', block: 'center' });
      });
      traceCell.append(button);
      row.append(traceCell);
      body.append(row);
    });
    table.append(head, body);
    target.append(table);
  }

  async function refresh(saveTokenAfterSuccess = false) {
    if (refreshInProgress) return false;
    refreshInProgress = true;
    try {
      message.textContent = '';
      const [overviewData, routeList, traces, errors, logs, instances, queries] = await Promise.all([
        request('overview'), request('routes'), request('traces'), request('errors'), request('logs'), request('instances'), request('queries')
      ]);
      if (saveTokenAfterSuccess) persistToken(token);
      routes = routeList;
      const overview = overviewData.overview;
      const sources = new Set(overviewData.availableSources || []);
      hasWindowMetrics = sources.has('http-window-metrics');
      $('service').textContent = `${overviewData.serviceName} · ${overviewData.environment}`;
      paintCards(overview);
      paintRoutes();
      $('updated').textContent = `Atualizado ${new Date(overview.generatedAt).toLocaleTimeString('pt-BR')}`;
      $('token-state').textContent = loadToken() === token ? 'Bearer salvo neste navegador' : 'Bearer ativo nesta sessão';
      paintTraces(traces);
      paintErrors(errors);
      paintRecords('logs-content', logs, (log) => record(
        `${log.severity} · ${new Date(log.timestamp).toLocaleTimeString('pt-BR')}`,
        `${log.routeTemplate || ''} ${log.message}${log.traceID ? ` · trace ${log.traceID}` : ''}`
      ), sources.has('redacted-logs') ? 'Nenhum evento redigido nesta janela.' : 'Sem fonte de logs redigidos conectada.');
      paintRecords('instances-content', instances, (instance) => record(
        `${instance.id} · ${instance.status}${instance.sampledAt ? ` · amostra ${new Date(instance.sampledAt).toLocaleTimeString('pt-BR')}` : ''}`,
        `CPU ${fmt(instance.cpuPercent, '%')} · RSS ${fmt(instance.memoryBytes == null ? null : instance.memoryBytes / 1024 / 1024, ' MB')}`
      ), sources.has('process-resources') ? 'Aguardando a primeira amostra do processo.' : 'Sem fonte de recursos conectada.');
      paintRecords('queries-content', queries, (query) => record(
        query.fingerprint,
        `${query.routeTemplate || 'rota não informada'} · ${fmt(query.executionCount)} execuções · ${fmt(query.errorCount || 0)} falhas · média ${fmt(query.averageLatencyMilliseconds, ' ms')} · p95 ${fmt(query.p95Milliseconds, ' ms')} · ${query.scope}`
      ), sources.has('database-query-metrics') ? 'Nenhuma query nesta janela.' : 'Sem fonte de métricas de queries conectada.');
      const instanceSelect = $('instance');
      const selectedInstance = instanceSelect.value;
      instanceSelect.replaceChildren(new Option('Todas / agregado', ''));
      instances.forEach((instance) => instanceSelect.add(new Option(instance.id, instance.id)));
      if ([...instanceSelect.options].some((option) => option.value === selectedInstance)) instanceSelect.value = selectedInstance;
      auth.hidden = true;
      dashboard.hidden = false;
      return true;
    } catch (error) {
      dashboard.hidden = true;
      auth.hidden = false;
      message.textContent = error instanceof Error ? error.message : 'Não foi possível consultar o DevKit.';
      return false;
    } finally {
      refreshInProgress = false;
    }
  }

  $('auth-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const submittedToken = $('token').value;
    token = submittedToken;
    $('token').value = '';
    const connected = await refresh(true);
    if (!connected && token) $('token').value = submittedToken;
  });
  $('refresh').addEventListener('click', () => refresh());
  $('period').addEventListener('change', () => refresh());
  $('instance').addEventListener('change', () => refresh());
  const showEmptyRoutesToggle = $('show-empty-routes');
  showEmptyRoutesToggle?.addEventListener('change', () => {
    showEmptyRoutes = showEmptyRoutesToggle.checked;
    paintRoutes();
  });
  $('disconnect').addEventListener('click', () => {
    removeStoredToken();
    token = '';
    $('token').value = '';
    $('token-state').textContent = '';
    message.textContent = 'Bearer removido deste navegador.';
    dashboard.hidden = true;
    auth.hidden = false;
  });
  $('search').addEventListener('input', paintRoutes);
  setInterval(() => {
    if (token && !dashboard.hidden) refresh();
  }, 10_000);
  document.querySelectorAll('.sidebar nav a').forEach((link) => {
    link.addEventListener('click', () => {
      document.querySelectorAll('.sidebar nav a').forEach((item) => item.classList.toggle('selected', item === link));
    });
  });

  token = loadToken();
  if (token) refresh();
})();
