// Logică UI: upload, rulare pași, polling status, deschidere viewer + features.
// Fără build step — vanilla JS (CLAUDE.md §10).

const state = {
  fileId: null,
  scanId: null,
};

function $(sel, root = document) { return root.querySelector(sel); }
function $all(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

// Citește parametrii editabili dintr-un container (data-param=...).
function collectParams(container) {
  const params = {};
  $all('[data-param]', container).forEach((el) => {
    const key = el.dataset.param;
    if (el.type === 'checkbox') {
      params[key] = el.checked;
    } else if (el.type === 'number') {
      if (el.value !== '') params[key] = parseFloat(el.value);
    } else {
      if (el.value !== '') params[key] = el.value;
    }
  });
  return params;
}

function setStatus(step, text, cls) {
  const el = document.getElementById(`status-${step}`);
  if (!el) return;
  el.className = `status ${cls || ''}`;
  el.textContent = text;
}

function renderLog(step, log) {
  const el = document.getElementById(`status-${step}`);
  if (!el) return;
  let pre = el.querySelector('pre');
  if (!pre) {
    pre = document.createElement('pre');
    pre.className = 'log';
    el.appendChild(pre);
  }
  pre.textContent = (log || []).slice(-40).join('\n');
  pre.scrollTop = pre.scrollHeight;
}

async function api(path, opts) {
  const res = await fetch(path, opts);
  if (!res.ok) {
    let detail = res.statusText;
    try { detail = (await res.json()).detail || detail; } catch (e) { /* ignore */ }
    throw new Error(detail);
  }
  return res.json();
}

// --- Upload ---
$('#uploadBtn').addEventListener('click', async () => {
  const input = $('#fileInput');
  if (!input.files.length) { setStatus('upload', 'Alege un fișier întâi.', 'error'); return; }
  const fd = new FormData();
  fd.append('file', input.files[0]);
  setStatus('upload', 'Se încarcă…', 'running');
  try {
    const res = await api('/api/upload', { method: 'POST', body: fd });
    state.fileId = res.file_id;
    state.scanId = res.file_id;
    setStatus('upload', `OK: ${res.filename} (${(res.size / 1e6).toFixed(1)} MB)`, 'done');
    if (res.ext !== '.e57') {
      setStatus('normalize', 'Skip (intrarea nu e E57).', 'skip');
    }
  } catch (e) {
    setStatus('upload', `Eroare: ${e.message}`, 'error');
  }
});

// --- Polling job ---
async function pollJob(step, jobId) {
  return new Promise((resolve, reject) => {
    const tick = async () => {
      try {
        const job = await api(`/api/jobs/${jobId}`);
        setStatus(step, `${job.status} — ${job.progress}%`, job.status);
        renderLog(step, job.log);
        if (job.status === 'done') return resolve(job);
        if (job.status === 'error') return reject(new Error(job.error || 'eroare job'));
        setTimeout(tick, 1000);
      } catch (e) {
        reject(e);
      }
    };
    tick();
  });
}

async function runStep(step, container) {
  if (!state.fileId) { setStatus(step, 'Încarcă un fișier întâi.', 'error'); return null; }
  const params = collectParams(container);
  setStatus(step, 'Se trimite…', 'running');
  try {
    const { job_id } = await api(`/api/run/${step}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file_id: state.fileId, params }),
    });
    return await pollJob(step, job_id);
  } catch (e) {
    setStatus(step, `Eroare: ${e.message}`, 'error');
    throw e;
  }
}

// --- Butoane Run pe pașii simpli ---
$all('.runBtn').forEach((btn) => {
  btn.addEventListener('click', async () => {
    const step = btn.dataset.step;
    const container = btn.closest('.step');
    try {
      const job = await runStep(step, container);
      if (step === 'potree' && job) {
        openViewer(job.result?.scan_id || state.scanId);
        loadFeatures(state.scanId);
      }
    } catch (e) { /* status deja setat */ }
  });
});

// --- Features (rulate secvențial pentru cele bifate) ---
$('#runFeaturesBtn').addEventListener('click', async () => {
  const fieldsets = $all('.feature').filter((fs) => $('.featChk', fs).checked);
  if (!fieldsets.length) { return; }
  for (const fs of fieldsets) {
    const step = fs.dataset.step;
    try {
      await runStep(step, fs);
    } catch (e) { /* continuă cu următoarea */ }
  }
  if (state.scanId) loadFeatures(state.scanId);
});

// --- Viewer Potree ---
function openViewer(scanId) {
  if (!scanId) return;
  state.scanId = scanId;
  $('#potreeFrame').src = `/viewer.html?scan=${encodeURIComponent(scanId)}`;
}

// --- Listă features disponibile ---
async function loadFeatures(scanId) {
  if (!scanId) return;
  try {
    const res = await api(`/api/features/${scanId}`);
    const list = $('#featuresList');
    list.innerHTML = '';
    if (!res.features.length) { list.textContent = 'Niciun feature încă.'; return; }
    res.features.forEach((f) => {
      const item = document.createElement('span');
      item.className = `feat-chip ${f.kind}`;
      if (f.kind === 'vector') {
        const a = document.createElement('a');
        a.href = '#'; a.textContent = f.name;
        a.addEventListener('click', (ev) => {
          ev.preventDefault();
          const frame = $('#potreeFrame');
          frame.contentWindow?.postMessage({ type: 'overlay', url: f.url, name: f.name }, '*');
        });
        item.appendChild(a);
      } else {
        const a = document.createElement('a');
        a.href = f.url; a.textContent = `${f.name} ⬇`; a.download = f.name;
        item.appendChild(a);
      }
      list.appendChild(item);
    });
  } catch (e) {
    $('#featuresList').textContent = `Eroare features: ${e.message}`;
  }
}
