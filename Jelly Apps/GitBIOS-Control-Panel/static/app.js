async function api(path, opts = {}) {
  const res = await fetch(path, Object.assign({ headers: { 'Accept': 'application/json' } }, opts));
  if (!res.ok) {
    let msg = '';
    try { msg = (await res.json()).error || await res.text(); } catch (_) {}
    throw new Error(msg || ('HTTP ' + res.status));
  }
  const ct = res.headers.get('content-type') || '';
  if (ct.includes('application/json')) return res.json();
  return res.text();
}

function logAppend(text) {
  const pre = document.getElementById('cp-log-pre');
  pre.textContent += (text || '') + '\n';
  pre.scrollTop = pre.scrollHeight;
}

function setBusy(b) {
  document.body.classList.toggle('cp-busy', !!b);
}

async function refreshProfiles() {
  const list = await api('/api/profiles');
  const sel = document.getElementById('cp-profile');
  const current = localStorage.getItem('cp.profile') || sel.value;
  sel.innerHTML = '';
  list.forEach(name => {
    const opt = document.createElement('option');
    opt.value = name; opt.textContent = name;
    sel.appendChild(opt);
  });
  sel.value = (current && list.includes(current)) ? current : (list[0] || '');
  localStorage.setItem('cp.profile', sel.value);
  if (sel.value) await loadProfile(sel.value);
}

async function loadProfile(name) {
  const data = await api('/api/profiles/' + encodeURIComponent(name));
  renderButtons(data, name);
}

function makeBadge(text) {
  const sp = document.createElement('span');
  sp.className = 'cp-badge';
  sp.textContent = text;
  return sp;
}

function renderButtons(buttons, profileName) {
  const wrap = document.getElementById('cp-buttons');
  wrap.innerHTML = '';
  buttons.forEach((btn, idx) => {
    const row = document.createElement('div');
    row.className = 'cp-button-row';

    const b = document.createElement('button');
    b.className = 'cp-button';
    b.textContent = btn.label;
    if (btn.interactive) b.appendChild(makeBadge('interactive'));

    b.onclick = async () => {
      try {
        if (btn.label.toUpperCase().includes('WARNING')) {
          if (!confirm('This action is marked WARNING:\n\n' + btn.label + '\n\nRun it now?')) return;
        }
        setBusy(true);
        logAppend('$ ' + btn.command);

        const headers = { 'Content-Type': 'application/json' };
        const token = (window.CP_TOKEN || '').trim();
        if (token) headers['Authorization'] = 'Bearer ' + token;

        const res = await api('/api/run', {
          method: 'POST',
          headers,
          body: JSON.stringify(btn)
        });

        // --- New logic for Terminator / tmux / non-interactive paths ---
        if (res.launched === 'terminator') {
          logAppend('[interactive] Launched in a new Terminator window' + (res.title ? ' (' + res.title + ')' : ''));
        } else if (res.attach) {
          logAppend('[interactive] attach with: ' + res.attach); // tmux fallback
        } else {
          logAppend(res.output || '[no output]');
          if (res.download) logAppend('Download: ' + location.origin + res.download);
          if (typeof res.exit_code === 'number') logAppend('[exit code ' + res.exit_code + ']');
        }
        // ---------------------------------------------------------------
      } catch (e) {
        logAppend('[ERROR] ' + e.message);
      } finally {
        setBusy(false);
      }
    };
    row.appendChild(b);

    const dots = document.createElement('button');
    dots.className = 'cp-ellipsis';
    dots.textContent = '⋮';
    dots.title = 'Edit';
    dots.onclick = async () => {
      const label = prompt('Edit label', btn.label);
      if (label === null) return;
      const command = prompt('Edit command', btn.command);
      if (command === null) return;
      const interactive = confirm('Interactive? OK=yes, Cancel=no');
      const payload = { label, command, interactive };

      const headers = { 'Content-Type': 'application/json' };
      const token = (window.CP_TOKEN || '').trim();
      if (token) headers['Authorization'] = 'Bearer ' + token;

      await api('/api/profiles/' + encodeURIComponent(profileName), {
        method: 'PUT',
        headers,
        body: JSON.stringify({ index: idx, value: payload })
      });
      await loadProfile(profileName);
    };
    row.appendChild(dots);
    wrap.appendChild(row);
  });

  const add = document.createElement('button');
  add.className = 'cp-button';
  add.textContent = '+ Add Button';
  add.onclick = async () => {
    const label = prompt('Label'); if (label === null) return;
    const command = prompt('Command'); if (command === null) return;
    const interactive = confirm('Interactive? OK=yes, Cancel=no');

    const headers = { 'Content-Type': 'application/json' };
    const token = (window.CP_TOKEN || '').trim();
    if (token) headers['Authorization'] = 'Bearer ' + token;

    await api('/api/profiles/' + encodeURIComponent(profileName), {
      method: 'PUT',
      headers,
      body: JSON.stringify({ append: { label, command, interactive } })
    });
    await loadProfile(profileName);
  };
  wrap.appendChild(add);
}

document.addEventListener('DOMContentLoaded', async () => {
  const sel = document.getElementById('cp-profile');
  sel.addEventListener('change', () => {
    localStorage.setItem('cp.profile', sel.value);
    loadProfile(sel.value);
  });

  document.getElementById('cp-refresh').onclick = refreshProfiles;

  document.getElementById('cp-new').onclick = async () => {
    const name = prompt('New profile name (no extension)');
    if (!name) return;

    const headers = { 'Content-Type': 'application/json' };
    const token = (window.CP_TOKEN || '').trim();
    if (token) headers['Authorization'] = 'Bearer ' + token;

    await api('/api/profiles', { method: 'POST', headers, body: JSON.stringify({ name, buttons: [] }) });
    await refreshProfiles();
  };

  document.getElementById('cp-export').onclick = () => {
    const name = sel.value; if (!name) return;
    window.location = '/api/profiles/export/' + encodeURIComponent(name);
  };

  document.getElementById('cp-import').onclick = async () => {
    const fileInput = document.createElement('input');
    fileInput.type = 'file'; fileInput.accept = 'application/json';
    fileInput.onchange = async () => {
      const f = fileInput.files[0]; if (!f) return;
      const fd = new FormData(); fd.append('file', f);

      const headers = {};
      const token = (window.CP_TOKEN || '').trim();
      if (token) headers['Authorization'] = 'Bearer ' + token;

      const res = await fetch('/api/profiles/import', { method: 'POST', headers, body: fd });
      if (!res.ok) { alert('Import failed'); return; }
      await refreshProfiles();
    };
    fileInput.click();
  };

  document.getElementById('cp-toggle').onclick = () => {
    document.getElementById('cp-dock').classList.add('hidden');
    document.getElementById('cp-fab').classList.remove('hidden');
  };
  document.getElementById('cp-fab').onclick = () => {
    document.getElementById('cp-dock').classList.remove('hidden');
    document.getElementById('cp-fab').classList.add('hidden');
  };

  await refreshProfiles();
});
